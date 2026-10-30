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
  """

  require Logger

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
    |> Task.async_stream(fn {name, spec} -> start_server(name, spec, timeout) end,
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
        stop_starting(name)
        %{server: name, status: {:error, {:exit, reason}}, tools: 0}
    end)
  end

  @doc "Names of the tools that MCP servers provide (`mcp__<server>__<tool>`)."
  def tool_names do
    ensure_routes!()
    @routes |> :ets.tab2list() |> Enum.map(&elem(&1, 0)) |> Enum.sort()
  end

  @doc """
  Runs an MCP tool by its exposed name and returns a `SuperPi.Tools` result map.
  An unknown name, a stopped server, or a protocol error is an `is_error` result, never a raise.
  """
  @spec call_tool(String.t(), map()) :: map()
  def call_tool(exposed_name, args) when is_binary(exposed_name) and is_map(args) do
    ensure_routes!()

    with [{^exposed_name, server, tool}] <- :ets.lookup(@routes, exposed_name),
         {:ok, pid} <- lookup_client(server),
         timeout = Application.get_env(:super_pi, :mcp_call_timeout_ms, 60_000),
         {:ok, result} <- Client.call_tool(pid, tool, args, timeout) do
      to_tool_result(result, server, tool)
    else
      [] -> error("MCP tool #{exposed_name} is not available (its server is not running)")
      :error -> error("MCP server for #{exposed_name} is not running")
      {:error, reason} -> error("MCP call #{exposed_name} failed: #{format_reason(reason)}")
    end
  end

  @doc "Stops every MCP server and removes their tools from the catalog."
  def stop_all do
    ensure_routes!()

    Enum.each(:ets.tab2list(@routes), fn {exposed, _server, _tool} ->
      :ets.delete(@catalog, exposed)
    end)

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

  defp start_server(name, spec, timeout) do
    case client_opts(name, spec) do
      {:ok, client_opts} ->
        # One launch per server at a time. A concurrent caller waits, then finds it running.
        :global.trans({{:mcp_launch, name}, self()}, fn ->
          case lookup_client(name) do
            {:ok, _pid} -> %{server: name, status: :running, tools: count_tools(name)}
            :error -> launch(name, client_opts, timeout)
          end
        end, [node()], :infinity)

      :error ->
        Logger.warning("[MCP] server #{name} has neither a `command` nor a `url`; skipped")
        %{server: name, status: {:error, :no_command_or_url}, tools: 0}
    end
  end

  # A `command` wins over a `url`, so an entry that has both keeps working as it did.
  defp client_opts(name, spec) do
    case {Map.get(spec, "command"), Map.get(spec, "url") || Map.get(spec, "serverUrl")} do
      {command, _url} when is_binary(command) and command != "" ->
        {:ok, [name: name, command: command, args: List.wrap(Map.get(spec, "args")), env: Map.get(spec, "env") || %{}]}

      {_none, url} when is_binary(url) and url != "" ->
        {:ok, [name: name, url: url, headers: Map.get(spec, "headers") || %{}]}

      _ ->
        :error
    end
  end

  defp launch(name, client_opts, timeout) do
    child = %{
      id: {:mcp_client, name},
      start: {Client, :start_link, [client_opts]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(@supervisor, child) do
      {:ok, pid} ->
        # Recorded before the handshake, so a failure or a killed launch can still stop it.
        :ets.insert(@clients, {{:starting, name}, pid})

        case Client.await_ready(pid, timeout) do
          :ok ->
            :ets.delete(@clients, {:starting, name})
            :ets.insert(@clients, {name, pid})
            %{server: name, status: :started, tools: register_tools(name, pid)}

          {:error, reason} = error ->
            Logger.warning("[MCP] server #{name} failed to start: #{format_reason(reason)}")
            stop_starting(name)
            %{server: name, status: error, tools: 0}
        end

      {:error, reason} = error ->
        Logger.warning("[MCP] server #{name} failed to start: #{format_reason(reason)}")
        %{server: name, status: error, tools: 0}
    end
  end

  defp stop_starting(name) do
    case :ets.lookup(@clients, {:starting, name}) do
      [{_, pid}] ->
        DynamicSupervisor.terminate_child(@supervisor, pid)
        :ets.delete(@clients, {:starting, name})

      [] ->
        :ok
    end
  end

  defp register_tools(server, pid) do
    exposure = Application.get_env(:super_pi, :mcp_tool_exposure, :direct)

    pid
    |> Client.tools()
    |> Enum.filter(&is_binary(&1["name"]))
    |> Enum.map(fn tool ->
      exposed = exposed_name(server, tool["name"])
      :ets.insert(@routes, {exposed, server, tool["name"]})

      Tools.register_tool!(
        %{
          "name" => exposed,
          "description" => "[MCP #{server}] " <> to_string(tool["description"] || tool["name"]),
          "input_schema" => tool["inputSchema"] || %{"type" => "object", "properties" => %{}},
          "effects" => effects(tool)
        },
        exposure
      )
    end)
    |> length()
  end

  # The server's own `readOnlyHint` is a claim, not a guarantee, but it is the only signal there
  # is. Without it the tool may write, so the policy treats it as a network write.
  @doc false
  def effects(%{"annotations" => %{"readOnlyHint" => true}}), do: ["net_read"]
  def effects(_tool), do: ["net_write"]

  defp lookup_client(name) do
    ensure_routes!()

    case :ets.lookup(@clients, name) do
      [{^name, pid}] -> if Process.alive?(pid), do: {:ok, pid}, else: :error
      [] -> :error
    end
  end

  defp count_tools(server) do
    ensure_routes!()
    Enum.count(:ets.tab2list(@routes), fn {_exposed, s, _tool} -> s == server end)
  end

  defp to_tool_result(result, server, tool) do
    text =
      result
      |> Map.get("content", [])
      |> List.wrap()
      |> Enum.map_join("\n", fn
        %{"type" => "text", "text" => t} -> to_string(t)
        %{"type" => type} = block -> "[#{type} content omitted] " <> Jason.encode!(Map.drop(block, ["data"]))
        other -> inspect(other)
      end)

    %{
      "output" => text,
      "structured_output" => Map.get(result, "structuredContent") || %{},
      "details" => %{"mcp_server" => server, "mcp_tool" => tool},
      "is_error" => Map.get(result, "isError") == true
    }
  end

  defp error(message) do
    %{"output" => message, "structured_output" => %{"error" => message}, "details" => %{}, "is_error" => true}
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

    :ok
  end

  defp sanitize(value), do: value |> to_string() |> String.replace(~r/[^A-Za-z0-9_-]/, "_")
end
