defmodule SuperPi.MCP.Manager do
  @moduledoc """
  Starts the MCP servers from `mcp_config.json` and exposes their tools to the agent.

  The file is the one that `super-pi mcp add|remove|enable|disable` edits (in the global
  config dir). Each enabled server is started once under `SuperPi.MCPClientSupervisor`.
  Its tools join the tool catalog as `mcp__<server>__<tool>`, so the model sees which server
  a tool belongs to and two servers cannot collide. `SuperPi.Tools.execute/3` routes those
  names to `call_tool/3`.

  Tool calls pass the same `before_tool` pipeline as built-in tools, so the permission
  policy applies. Every MCP tool is registered with an `"effects"` list, which is what the
  policy decides by (`SuperPi.Plugins.Permissions`): `["net_read"]` when the server annotates
  the tool `readOnlyHint: true`, else `["net_write"]`. A read-only tool runs without a prompt
  under `accept-edits` and in `plan` mode. Any other tool needs `auto` mode, a prompt answer,
  `permissions.allowTools`, or `dangerouslySkipPermissions`. The `network` policy (`deny`,
  `allowlist`) applies to every MCP tool, a local stdio one included, because the server may
  do anything.

  ## Configuration

      config :super_pi,
        mcp_clients: true,           # start servers when a conversation starts
        mcp_tool_exposure: :direct,  # or :deferred (found through `tool_search`)
        mcp_startup_timeout_ms: 10_000,
        mcp_call_timeout_ms: 60_000

  ## Server entries

  Each entry under `"mcpServers"` is one of two shapes. Both accept `"disabled": true`.

  A local process, over stdio:

      {"command": "npx", "args": ["-y", "some-server"], "env": {"TOKEN": "..."}}

  A hosted server, over Streamable HTTP (`url`, or `serverUrl` as other hosts write it):

      {"url": "https://mcp.example.com/mcp",
       "headers": {"Authorization": "Bearer ${EXAMPLE_TOKEN}"}}

  `${NAME}` in a header value is replaced from the environment at start-up. A name that is not
  set fails that server with `{:missing_env, names}`. OAuth is not supported. See
  `SuperPi.MCP.Transport.StreamableHTTP` for the session and fallback behaviour. An entry with
  both `command` and `url` runs the command.

  ## Scopes

  A server belongs to a scope. The servers from `mcp_config.json` are `:global`: every
  conversation sees their tools. The servers that a client hands over at run time
  (`add_servers/2`) belong to one conversation. Their tools stay out of the shared catalog, only
  that conversation declares them, and only a call from that conversation reaches them. Two
  conversations that hand over a server with the same name get two processes, each with its own
  `env` and `headers`.
  """

  require Logger

  alias SuperPi.Durable.{Doc, Storage}
  alias SuperPi.MCP.Client
  alias SuperPi.Plugins.TranscriptLogger
  alias SuperPi.Tools

  @supervisor SuperPi.MCPClientSupervisor
  @routes :super_pi_mcp_routes
  @clients :super_pi_mcp_clients
  @catalog :super_pi_tool_catalog

  @doc """
  Starts every enabled stdio server that is not running yet and registers its tools.
  Returns `[%{server: name, status: :started | :running | {:error, reason}, tools: count}]`.
  Servers that fail to start are logged and skipped. The call is safe to repeat.
  """
  @spec ensure_started(keyword()) :: [map()]
  def ensure_started(opts \\ []) do
    ensure_routes!()
    timeout = Application.get_env(:super_pi, :mcp_startup_timeout_ms, 10_000)

    specs = opts |> TranscriptLogger.mcp_specs() |> Enum.sort_by(&elem(&1, 0))

    specs
    |> Task.async_stream(fn {name, spec} -> start_server(:global, name, spec, timeout) end,
      max_concurrency: 8,
      timeout: timeout + 2_000,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.zip(specs)
    |> Enum.map(fn
      {{:ok, result}, _spec} ->
        result

      {{:exit, reason}, {name, _spec}} ->
        # The task was killed mid-launch. Stop the client it had started, or its OS process leaks.
        stop_starting(:global, name)
        %{server: name, status: {:error, {:exit, reason}}, tools: 0}
    end)
  end

  @doc """
  Starts MCP servers that a client hands over at run time, in the ACP `mcpServers` shape:

  - stdio: `%{"name", "command", "args", "env" => [%{"name", "value"}]}`
  - HTTP: `%{"type" => "http" | "sse", "name", "url", "headers" => [%{"name", "value"}]}`

  The servers belong to `conversation_id` (see "Scopes"), and their tools are declared in its
  agent document. A server that is already running for that conversation is left alone, and one
  that fails to start is logged and skipped. Returns the same list as `ensure_started/1`.
  """
  @spec add_servers(term(), [map()]) :: [map()]
  def add_servers(conversation_id, servers) when is_list(servers) do
    ensure_routes!()
    timeout = Application.get_env(:super_pi, :mcp_startup_timeout_ms, 10_000)

    results =
      for %{"name" => name} = server <- servers, is_binary(name), name != "" do
        start_server(conversation_id, name, acp_spec(server), timeout)
      end

    declare_tools(conversation_id)
    results
  end

  @doc """
  Adds the MCP tools that `conversation_id` may use, and does not declare yet, to its agent
  document: the `:global` tools that the catalog shows the model, and the tools of its own servers.
  """
  @spec declare_tools(term()) :: :ok
  def declare_tools(conversation_id) do
    # The machine and an ACP session both declare. A lock keeps one update from losing the other.
    :global.trans({{:mcp_declare, conversation_id}, self()}, fn ->
      agent = Doc.snapshot("conversation", conversation_id, "pi.agent") || %{}
      tools = Map.get(agent, "tools", [])
      declared = MapSet.new(tools, & &1["name"])

      # Its own tools first: `call_tool/3` prefers them over a `:global` tool of the same name.
      new_tools =
        (scope_tools(conversation_id) ++
           Enum.filter(Tools.active_llm_tools(), &String.starts_with?(&1["name"], "mcp__")))
        |> Enum.reject(&MapSet.member?(declared, &1["name"]))
        |> Enum.uniq_by(& &1["name"])

      if new_tools != [],
        do: Storage.configure_agent!(conversation_id, %{"tools" => tools ++ new_tools})
    end)

    :ok
  end

  defp scope_tools(:global), do: []

  defp scope_tools(scope) do
    ensure_routes!()
    for {{^scope, _exposed}, _server, _tool, spec} <- :ets.tab2list(@routes), do: spec
  end

  # ACP lists env and headers as `[{name, value}]`. The configuration file uses a map.
  defp acp_spec(server) do
    server
    |> Map.take(["command", "args", "url"])
    |> put_pairs("env", server["env"])
    |> put_pairs("headers", server["headers"])
  end

  defp put_pairs(spec, key, pairs) when is_list(pairs) and pairs != [] do
    Map.put(spec, key, Map.new(pairs, fn %{"name" => n, "value" => v} -> {n, v} end))
  end

  defp put_pairs(spec, _key, _pairs), do: spec

  @doc "Names of the tools that the servers of `scope` provide (`mcp__<server>__<tool>`)."
  def tool_names(scope \\ :global) do
    ensure_routes!()

    for({{^scope, exposed}, _server, _tool, _spec} <- :ets.tab2list(@routes), do: exposed)
    |> Enum.sort()
  end

  @doc """
  Runs an MCP tool by its exposed name and returns a `SuperPi.Tools` result map. `scope` is the
  calling conversation: its own servers come first, then the `:global` ones. A tool of another
  conversation's server is not available.
  An unknown name, a stopped server, or a protocol error is an `is_error` result, never a raise.
  """
  @spec call_tool(String.t(), map(), term()) :: map()
  def call_tool(exposed_name, args, scope \\ :global)
      when is_binary(exposed_name) and is_map(args) do
    ensure_routes!()

    with {route_scope, server, tool} <- route(scope, exposed_name),
         {:ok, pid} <- lookup_client(route_scope, server),
         timeout = Application.get_env(:super_pi, :mcp_call_timeout_ms, 60_000),
         {:ok, result} <- Client.call_tool(pid, tool, args, timeout) do
      to_tool_result(result, server, tool)
    else
      nil -> error("MCP tool #{exposed_name} is not available (its server is not running)")
      :error -> error("MCP server for #{exposed_name} is not running")
      {:error, reason} -> error("MCP call #{exposed_name} failed: #{format_reason(reason)}")
    end
  end

  defp route(scope, exposed_name) do
    Enum.find_value(Enum.uniq([scope, :global]), fn s ->
      case :ets.lookup(@routes, {s, exposed_name}) do
        [{_key, server, tool, _spec}] -> {s, server, tool}
        [] -> nil
      end
    end)
  end

  @doc """
  Stops the servers of one conversation and forgets their tools. The tools stay declared in its
  agent document, so a call fails as "not available" until the client hands the servers over again.
  """
  @spec stop_scope(term()) :: :ok
  def stop_scope(:global), do: :ok

  def stop_scope(scope) do
    ensure_routes!()
    :ets.match_delete(@routes, {{scope, :_}, :_, :_, :_})

    for {{^scope, _name} = key, pid} <- :ets.tab2list(@clients) do
      :ets.delete(@clients, key)
      terminate(pid)
    end

    :ok
  end

  defp terminate(pid) do
    if Process.whereis(@supervisor), do: DynamicSupervisor.terminate_child(@supervisor, pid)
  end

  @doc "Stops every MCP server and removes their tools from the catalog."
  def stop_all do
    ensure_routes!()

    for {{:global, exposed}, _server, _tool, _spec} <- :ets.tab2list(@routes),
        do: :ets.delete(@catalog, exposed)

    :ets.delete_all_objects(@routes)
    :ets.delete_all_objects(@clients)

    if Process.whereis(@supervisor) do
      @supervisor
      |> DynamicSupervisor.which_children()
      |> Enum.each(fn {_, pid, _, _} -> DynamicSupervisor.terminate_child(@supervisor, pid) end)
    end

    :ok
  end

  @doc "The exposed tool name for a server and tool: `mcp__<server>__<tool>`, characters limited to `[A-Za-z0-9_-]`."
  def exposed_name(server, tool), do: "mcp__#{sanitize(server)}__#{sanitize(tool)}"

  # --- Internals ---

  defp start_server(scope, name, spec, timeout) do
    case client_opts(name, spec) do
      {:ok, client_opts} ->
        # One launch per server at a time. A concurrent caller waits, then finds it running.
        :global.trans(
          {{:mcp_launch, scope, name}, self()},
          fn ->
            case lookup_client(scope, name) do
              {:ok, _pid} -> %{server: name, status: :running, tools: count_tools(scope, name)}
              :error -> launch(scope, name, client_opts, timeout)
            end
          end,
          [node()],
          :infinity
        )

      :error ->
        Logger.warning("[MCP] server #{name} has neither a `command` nor a `url`; skipped")
        %{server: name, status: {:error, :no_command_or_url}, tools: 0}
    end
  end

  # A `command` wins over a `url`, so an entry that has both keeps working as it did.
  defp client_opts(name, spec) do
    case {Map.get(spec, "command"), Map.get(spec, "url") || Map.get(spec, "serverUrl")} do
      {command, _url} when is_binary(command) and command != "" ->
        {:ok,
         [
           name: name,
           command: command,
           args: List.wrap(Map.get(spec, "args")),
           env: Map.get(spec, "env") || %{}
         ]}

      {_none, url} when is_binary(url) and url != "" ->
        {:ok, [name: name, url: url, headers: Map.get(spec, "headers") || %{}]}

      _ ->
        :error
    end
  end

  defp launch(scope, name, client_opts, timeout) do
    child = %{
      id: {:mcp_client, scope, name},
      start: {Client, :start_link, [client_opts]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(@supervisor, child) do
      {:ok, pid} ->
        # Recorded before the handshake, so a failure or a killed launch can still stop it.
        :ets.insert(@clients, {{:starting, scope, name}, pid})

        case Client.await_ready(pid, timeout) do
          :ok ->
            :ets.delete(@clients, {:starting, scope, name})
            :ets.insert(@clients, {{scope, name}, pid})
            %{server: name, status: :started, tools: register_tools(scope, name, pid)}

          {:error, reason} = error ->
            Logger.warning("[MCP] server #{name} failed to start: #{format_reason(reason)}")
            stop_starting(scope, name)
            %{server: name, status: error, tools: 0}
        end

      {:error, reason} = error ->
        Logger.warning("[MCP] server #{name} failed to start: #{format_reason(reason)}")
        %{server: name, status: error, tools: 0}
    end
  end

  defp stop_starting(scope, name) do
    case :ets.lookup(@clients, {:starting, scope, name}) do
      [{_, pid}] ->
        DynamicSupervisor.terminate_child(@supervisor, pid)
        :ets.delete(@clients, {:starting, scope, name})

      [] ->
        :ok
    end
  end

  # `:global` tools join the shared catalog. A conversation's tools stay in the routes table, with
  # their spec, and are always `:direct`: the client handed them over to be used.
  defp register_tools(scope, server, pid) do
    exposure = Application.get_env(:super_pi, :mcp_tool_exposure, :direct)

    pid
    |> Client.tools()
    |> Enum.filter(&is_binary(&1["name"]))
    |> Enum.map(fn tool ->
      exposed = exposed_name(server, tool["name"])

      spec = %{
        "name" => exposed,
        "description" => "[MCP #{server}] " <> to_string(tool["description"] || tool["name"]),
        "input_schema" => tool["inputSchema"] || %{"type" => "object", "properties" => %{}},
        "effects" => effects(tool)
      }

      if scope == :global do
        :ets.insert(@routes, {{scope, exposed}, server, tool["name"], nil})
        Tools.register_tool!(spec, exposure)
      else
        entry = Tools.tool_entry(spec, :direct)
        :ets.insert(@routes, {{scope, exposed}, server, tool["name"], entry})
      end
    end)
    |> length()
  end

  # The server's own `readOnlyHint` is a claim, not a guarantee, but it is the only signal there
  # is. Without it the tool may write, so the policy treats it as a network write.
  @doc false
  def effects(%{"annotations" => %{"readOnlyHint" => true}}), do: ["net_read"]
  def effects(_tool), do: ["net_write"]

  defp lookup_client(scope, name) do
    ensure_routes!()

    case :ets.lookup(@clients, {scope, name}) do
      [{_key, pid}] -> if Process.alive?(pid), do: {:ok, pid}, else: :error
      [] -> :error
    end
  end

  defp count_tools(scope, server) do
    ensure_routes!()

    Enum.count(:ets.tab2list(@routes), fn {{s, _exposed}, srv, _tool, _spec} ->
      s == scope and srv == server
    end)
  end

  defp to_tool_result(result, server, tool) do
    text =
      result
      |> Map.get("content", [])
      |> List.wrap()
      |> Enum.map_join("\n", fn
        %{"type" => "text", "text" => t} ->
          to_string(t)

        %{"type" => type} = block ->
          "[#{type} content omitted] " <> Jason.encode!(Map.drop(block, ["data"]))

        other ->
          inspect(other)
      end)

    %{
      "output" => text,
      "structured_output" => Map.get(result, "structuredContent") || %{},
      "details" => %{"mcp_server" => server, "mcp_tool" => tool},
      "is_error" => Map.get(result, "isError") == true
    }
  end

  defp error(message) do
    %{
      "output" => message,
      "structured_output" => %{"error" => message},
      "details" => %{},
      "is_error" => true
    }
  end

  defp format_reason({:protocol_error, %{"message" => message}}), do: message
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  # Public tables, created on first use by whichever process gets there first. A table owned by a
  # short-lived caller would vanish with it, so the application owner creates them at boot
  # (`create_tables/0`); this only covers calls before that.
  defp ensure_routes!, do: create_tables()

  @doc false
  def create_tables do
    for table <- [@routes, @clients], :ets.whereis(table) == :undefined do
      try do
        :ets.new(table, [:named_table, :public, :set])
      rescue
        ArgumentError -> :ok
      end
    end

    # Same owner and same reason, for the HTTP server's sessions.
    SuperPi.MCP.Sessions.create_table()
  end

  defp sanitize(value), do: value |> to_string() |> String.replace(~r/[^A-Za-z0-9_-]/, "_")
end
