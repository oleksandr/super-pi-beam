defmodule SuperPi.ACP.Server do
  @moduledoc """
  Agent Client Protocol agent over stdio: `bin/super-pi acp`.

  Editors (Zed, JetBrains, GitHub Copilot CLI, the neovim plugins) start the agent as a subprocess and
  speak JSON-RPC 2.0, one message per line. ACP is bidirectional: the agent also sends requests
  (`session/request_permission`, `fs/read_text_file`) and waits for the answer. So this is not
  `SuperPi.RPC.Server`: that module only replies and notifies and has no table of outstanding
  requests. Here a `pending` table maps each outgoing request id to what waits for it.

  ## Methods

  | ACP | Super-Pi |
  |---|---|
  | `initialize` | Agent capabilities, `authMethods` from `Auth.required?/0`, harness capabilities in `_meta.superPi.harnesses` |
  | `authenticate` | The token store of `auth.login` (token in `_meta.token` or `SUPER_PI_GATEWAY_TOKEN`) |
  | `session/new` | A conversation with `workspacePaths: [cwd]`. `_meta.harness` picks the harness. `mcpServers` are applied to the MCP manager |
  | `session/load` | Resume (not fork): replays history as `session/update` notifications, then answers |
  | `_superpi/session/fork` | Fork at the latest entry into a new session (ACP's `_` convention for custom methods) |
  | `session/prompt` | Submits in a supervised task, so `session/cancel` can arrive during the prompt |
  | `session/cancel` | `UI.Broker.cancel_pending/1`, then `Machine.cancel/1`, in that order |
  | `session/set_mode` | Sets `executionMode` within the remote ceiling and the harness ceiling |

  `stopReason`: `end_turn` for a finished turn, `cancelled` for a cancel, `refusal` for an error (the
  error text goes to the client as a message chunk first).

  ## Terminals and files

  `terminal/*` is never delegated: `SandboxRunner` gives process-group kill, output spill and the
  sandbox, and an editor terminal gives none of that and bypasses `permissions.deny`. A running command
  is a `tool_call` of kind `execute`.

  `config :super_pi, :acp, fs_delegation: :unsaved_only | :never | :always` (default
  `:unsaved_only`). `fs/read_text_file` returns the unsaved editor buffer, the only reason to delegate.
  `SuperPi.Env.ClientFS` asks the client only when the client advertised the method, the machine runs
  on this node (the editor's files do not exist on another node) and the path is inside the
  workspace. Writes always stay on the server.

  ## Transport

  `run_stdio/1` starts the server and reads standard input. Output is one JSON object per line on
  standard output, so logs must go to standard error (`SUPER_PI_LOG_STDERR=1`, set by `bin/super-pi`).
  For tests, `start_link(send: fun)` and `send(server, {:acp_line, line})`.
  """

  use GenServer

  alias SuperPi.ACP.Session
  alias SuperPi.Auth
  alias SuperPi.Conversation.Machine
  alias SuperPi.Event
  alias SuperPi.Event.Renderer
  alias SuperPi.Harness
  alias SuperPi.UI.Broker

  @protocol_version 1
  @prompt_timeout_ms 600_000
  @fs_timeout_ms 10_000

  defstruct send: nil,
            client_caps: %{},
            initialized?: false,
            principal: nil,
            sessions: %{},
            by_conversation: %{},
            pending: %{},
            next_id: 1

  # --- API ---

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

  @doc "Starts the server on standard input and output and returns when the input ends."
  def run_stdio(opts \\ []) do
    {:ok, pid} = start_link(Keyword.put_new(opts, :send, fn line -> IO.puts(:stdio, line) end))
    ref = Process.monitor(pid)

    reader =
      spawn_link(fn ->
        for line <- IO.stream(:stdio, :line),
            String.trim(line) != "",
            do: send(pid, {:acp_line, String.trim(line)})

        GenServer.stop(pid)
      end)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> Process.exit(reader, :normal)
    end

    :ok
  end

  @doc "Asks the client for the text of a file, including unsaved changes. Used by `SuperPi.Env.ClientFS`."
  @spec read_text_file(pid(), integer(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def read_text_file(server, conversation_id, path, opts \\ []) do
    GenServer.call(server, {:fs_read, conversation_id, path, opts}, @fs_timeout_ms + 1_000)
  catch
    :exit, reason -> {:error, reason}
  end

  # --- GenServer ---

  @impl true
  def init(opts) do
    send_fun =
      Keyword.get(opts, :send) || raise ArgumentError, "ACP.Server needs a :send function"

    {:ok, %__MODULE__{send: send_fun}}
  end

  # The client owns the servers it handed over, so they end with its connection.
  @impl true
  def terminate(_reason, st) do
    Enum.each(Map.keys(st.by_conversation), &SuperPi.MCP.Manager.stop_scope/1)
  end

  @impl true
  def handle_info({:acp_line, line}, st) do
    case Jason.decode(line) do
      {:ok, %{"method" => method} = msg} ->
        {:noreply,
         handle_message(
           method,
           Map.get(msg, "id"),
           Map.get(msg, "params") || %{},
           open_principal(st)
         )}

      {:ok, %{"id" => id} = msg} when is_map_key(msg, "result") or is_map_key(msg, "error") ->
        {:noreply, handle_response(id, msg, st)}

      {:ok, _} ->
        {:noreply, reply_error(st, nil, -32600, "Invalid request")}

      {:error, _} ->
        {:noreply, reply_error(st, nil, -32700, "Parse error")}
    end
  end

  def handle_info({:conversation_event, conv_id, wire}, st) do
    case Map.get(st.by_conversation, conv_id) do
      nil -> {:noreply, st}
      session_id -> {:noreply, handle_event(session_id, Event.from_wire(wire), st)}
    end
  end

  # A prompt task ended. Events published before its reply are already queued, so take them first.
  def handle_info({ref, result}, st) when is_reference(ref) do
    case find_prompt(st, ref) do
      nil ->
        {:noreply, st}

      session_id ->
        Process.demonitor(ref, [:flush])
        st = drain_events(st)
        {:noreply, finish_prompt(session_id, result, st)}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, st) do
    case find_prompt(st, ref) do
      nil -> {:noreply, st}
      session_id -> {:noreply, finish_prompt(session_id, {:error, {:crashed, reason}}, st)}
    end
  end

  def handle_info({:fs_timeout, id}, st) do
    case Map.pop(st.pending, id) do
      {{:fs_read, from}, rest} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{st | pending: rest}}

      _ ->
        {:noreply, st}
    end
  end

  def handle_info(_other, st), do: {:noreply, st}

  @impl true
  def handle_call({:fs_read, conversation_id, path, opts}, from, st) do
    case Map.get(st.by_conversation, conversation_id) do
      nil ->
        {:reply, {:error, :no_session}, st}

      session_id ->
        {id, st} = next_id(st)

        params =
          %{"sessionId" => session_id, "path" => path}
          |> maybe_put("line", opts[:line])
          |> maybe_put("limit", opts[:limit])

        Process.send_after(self(), {:fs_timeout, id}, @fs_timeout_ms)
        st = put_in(st.pending[id], {:fs_read, from})
        {:noreply, send_request(st, id, "fs/read_text_file", params)}
    end
  end

  # With no gateway token configured the endpoint is open, and the principal is `anonymous`. The
  # check runs for each message, because the token configuration can change while the server runs.
  defp open_principal(%{principal: nil} = st),
    do: if(Auth.required?(), do: st, else: %{st | principal: Auth.anonymous()})

  defp open_principal(st), do: st

  # --- Requests and notifications from the client ---

  defp handle_message("initialize", id, params, st) do
    caps = Map.get(params, "clientCapabilities") || %{}

    result = %{
      "protocolVersion" =>
        min(Map.get(params, "protocolVersion", @protocol_version), @protocol_version),
      "agentCapabilities" => %{
        "loadSession" => true,
        "promptCapabilities" => %{"image" => false, "audio" => false, "embeddedContext" => true},
        "mcpCapabilities" => %{"http" => true, "sse" => true}
      },
      "agentInfo" => %{"name" => "super-pi", "title" => "Super-Pi-BEAM", "version" => "0.1.0"},
      "authMethods" => auth_methods(),
      "_meta" => %{
        "superPi" => %{"harnesses" => Enum.map(Harness.list(), &Harness.capabilities/1)}
      }
    }

    st = %{st | client_caps: caps, initialized?: true}
    reply(st, id, result)
  end

  defp handle_message("authenticate", id, params, st) do
    token = get_in(params, ["_meta", "token"]) || System.get_env("SUPER_PI_GATEWAY_TOKEN")

    case Auth.authenticate(token) do
      {:ok, principal} -> reply(%{st | principal: principal}, id, %{})
      :error -> reply_error(st, id, -32000, "Authentication failed")
    end
  end

  defp handle_message(method, id, _params, %{principal: nil} = st)
       when method in [
              "session/new",
              "session/load",
              "session/prompt",
              "session/set_mode",
              "_superpi/session/fork"
            ] do
    reply_error(st, id, -32000, "Authentication required")
  end

  defp handle_message("session/new", id, params, st) do
    with {:ok, cwd} <- fetch_cwd(params),
         {:ok, harness} <- Session.pick_harness(params["_meta"]) do
      session = Session.create(st.principal, cwd, harness)
      apply_mcp_servers(session, params["mcpServers"])
      st = attach(st, session)

      st
      |> reply(id, %{"sessionId" => session.id, "modes" => Session.modes(session.conversation_id)})
      |> send_commands(session)
    else
      {:error, message} -> reply_error(st, id, -32602, message)
    end
  end

  defp handle_message("session/load", id, params, st) do
    with {:ok, cwd} <- fetch_cwd(params),
         {:ok, session_id} <- fetch_string(params, "sessionId"),
         {:ok, session} <- Session.load(st.principal, session_id, cwd) |> or_not_found(session_id) do
      apply_mcp_servers(session, params["mcpServers"])
      st = attach(st, session)
      st = Enum.reduce(Session.replay(session), st, &notify_update(&2, session.id, &1))

      st
      |> reply(id, %{"modes" => Session.modes(session.conversation_id)})
      |> send_commands(session)
    else
      {:error, :not_found, message} -> reply_error(st, id, -32002, message)
      {:error, message} -> reply_error(st, id, -32602, message)
    end
  end

  defp handle_message("_superpi/session/fork", id, params, st) do
    with {:ok, session} <- fetch_session(st, params),
         {:ok, forked} <- Session.fork(st.principal, session) do
      st = attach(st, forked)
      reply(st, id, %{"sessionId" => forked.id})
    else
      {:error, reason} -> reply_error(st, id, -32602, "Cannot fork: #{inspect(reason)}")
    end
  end

  defp handle_message("session/prompt", id, params, st) do
    with {:ok, session} <- fetch_session(st, params),
         nil <- session.prompt,
         {:ok, text} <- prompt_text(params["prompt"]) do
      start_prompt(st, session, id, text)
    else
      %{} -> reply_error(st, id, -32602, "A prompt is already running in this session")
      {:error, message} -> reply_error(st, id, -32602, message)
    end
  end

  defp handle_message("session/cancel", _id, params, st) do
    case fetch_session(st, params) do
      {:ok, session} -> Session.cancel(session)
      _ -> :ok
    end

    st
  end

  defp handle_message("session/set_mode", id, params, st) do
    with {:ok, session} <- fetch_session(st, params),
         :ok <- Session.set_mode(session.conversation_id, params["modeId"]) do
      reply(st, id, %{})
    else
      {:error, message} -> reply_error(st, id, -32602, message)
    end
  end

  defp handle_message("ping", id, _params, st), do: reply(st, id, %{})

  defp handle_message(method, id, _params, st) do
    if id == nil, do: st, else: reply_error(st, id, -32601, "Method not found: #{method}")
  end

  # --- Responses from the client ---

  defp handle_response(id, msg, st) do
    case Map.pop(st.pending, id) do
      {nil, _} ->
        st

      {{:permission, broker_request_id}, rest} ->
        answer_permission(broker_request_id, msg)
        %{st | pending: rest}

      {{:fs_read, from}, rest} ->
        GenServer.reply(from, fs_result(msg))
        %{st | pending: rest}
    end
  end

  # `selected` carries the option id. `cancelled` means the client dropped the prompt, which ends the turn.
  defp answer_permission(broker_request_id, %{
         "result" => %{"outcome" => %{"outcome" => "selected", "optionId" => option}}
       }),
       do: Broker.respond(broker_request_id, option)

  defp answer_permission(broker_request_id, _other) do
    case Broker.conversation_of(broker_request_id) do
      nil -> :ok
      conv_id -> Broker.cancel_pending(conv_id)
    end
  end

  defp fs_result(%{"result" => %{"content" => content}}) when is_binary(content),
    do: {:ok, content}

  defp fs_result(%{"error" => %{"message" => message}}), do: {:error, message}
  defp fs_result(_), do: {:error, :bad_response}

  # --- Prompt ---

  defp start_prompt(st, session, rpc_id, text) do
    pid =
      SuperPi.Conversation.Locator.ensure_started!(
        session.conversation_id,
        Harness.remote_extensions(harness_of(session))
      )

    Broker.register_responder(session.conversation_id)
    register_fs(session.conversation_id, st)

    task =
      Task.Supervisor.async_nolink(SuperPi.ToolTaskSupervisor, fn ->
        Machine.safe_submit(pid, text, mode: :queue, timeout: @prompt_timeout_ms)
      end)

    put_session(st, %{session | prompt: %{id: rpc_id, ref: task.ref}, last_end: nil})
  end

  defp finish_prompt(session_id, result, st) do
    session = Map.fetch!(st.sessions, session_id)
    %{id: rpc_id} = session.prompt

    {st, stop_reason} =
      case result do
        {:ok, _} ->
          {st, "end_turn"}

        {:error, :cancelled} ->
          {st, "cancelled"}

        {:error, reason} ->
          if session.last_end == "turn_cancelled" do
            {st, "cancelled"}
          else
            {notify_update(st, session_id, %{
               "sessionUpdate" => "agent_message_chunk",
               "content" => %{"type" => "text", "text" => "**Error:** #{format_reason(reason)}"}
             }), "refusal"}
          end
      end

    st = put_session(st, %{Map.fetch!(st.sessions, session_id) | prompt: nil})
    reply(st, rpc_id, %{"stopReason" => stop_reason})
  end

  defp find_prompt(st, ref) do
    Enum.find_value(st.sessions, fn {id, s} -> match?(%{ref: ^ref}, s.prompt) && id end)
  end

  defp drain_events(st) do
    receive do
      {:conversation_event, conv_id, wire} ->
        st =
          case Map.get(st.by_conversation, conv_id) do
            nil -> st
            session_id -> handle_event(session_id, Event.from_wire(wire), st)
          end

        drain_events(st)
    after
      0 -> st
    end
  end

  defp prompt_text(blocks) when is_list(blocks) do
    text =
      blocks
      |> Enum.map(fn
        %{"type" => "text", "text" => t} -> t
        %{"type" => "resource_link", "uri" => uri} -> "[#{uri}]"
        %{"type" => "resource", "resource" => %{"uri" => uri, "text" => t}} -> "[#{uri}]\n#{t}"
        _ -> ""
      end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    if String.trim(text) == "", do: {:error, "The prompt has no text"}, else: {:ok, text}
  end

  defp prompt_text(_), do: {:error, "`prompt` must be a list of content blocks"}

  defp harness_of(session) do
    agent =
      SuperPi.Durable.Doc.snapshot("conversation", session.conversation_id, "pi.agent") || %{}

    # The conversation keeps the loadout and prompt of its harness. The extensions come from the
    # harness named in the model field when there is one, else the default.
    case Harness.fetch(agent["harness"] || Harness.default().id()) do
      {:ok, mod} -> mod
      _ -> Harness.default()
    end
  end

  # --- Events ---

  defp handle_event(session_id, %Event{type: type} = ev, st)
       when type in ["turn_completed", "turn_cancelled", "turn_error"] do
    session = Map.fetch!(st.sessions, session_id)
    put_session(st, %{session | last_end: type}) |> render_event(session_id, ev)
  end

  defp handle_event(session_id, ev, st), do: render_event(st, session_id, ev)

  defp render_event(st, session_id, ev) do
    session = Map.fetch!(st.sessions, session_id)
    {items, renderer} = Renderer.ACP.render(ev, session.renderer)
    st = put_session(st, %{Map.fetch!(st.sessions, session_id) | renderer: renderer})

    Enum.reduce(items, st, fn
      {:update, update}, acc ->
        notify_update(acc, session_id, update)

      {:permission, params, broker_request_id}, acc ->
        {id, acc} = next_id(acc)
        acc = put_in(acc.pending[id], {:permission, broker_request_id})
        send_request(acc, id, "session/request_permission", params)
    end)
  end

  # --- Wire ---

  defp reply(st, nil, _result), do: st
  defp reply(st, id, result), do: emit(st, %{"jsonrpc" => "2.0", "id" => id, "result" => result})

  defp reply_error(st, id, code, message),
    do:
      emit(st, %{
        "jsonrpc" => "2.0",
        "id" => id,
        "error" => %{"code" => code, "message" => message}
      })

  defp notify_update(st, session_id, update) do
    emit(st, %{
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => %{"sessionId" => session_id, "update" => update}
    })
  end

  defp send_request(st, id, method, params),
    do: emit(st, %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})

  defp emit(st, map) do
    st.send.(Jason.encode!(map))
    st
  end

  defp send_commands(st, session) do
    commands =
      Enum.map(
        SuperPi.CLI.slash_commands(),
        &%{"name" => String.trim_leading(&1["name"], "/"), "description" => &1["description"]}
      )

    notify_update(st, session.id, %{
      "sessionUpdate" => "available_commands_update",
      "availableCommands" => commands
    })
  end

  defp next_id(st), do: {"agent-#{st.next_id}", %{st | next_id: st.next_id + 1}}

  # --- Sessions ---

  defp attach(st, session) do
    Phoenix.PubSub.unsubscribe(SuperPi.PubSub, Event.topic(session.conversation_id))
    Phoenix.PubSub.subscribe(SuperPi.PubSub, Event.topic(session.conversation_id))
    Broker.register_responder(session.conversation_id)
    register_fs(session.conversation_id, st)
    st = put_session(st, session)
    %{st | by_conversation: Map.put(st.by_conversation, session.conversation_id, session.id)}
  end

  defp put_session(st, session), do: %{st | sessions: Map.put(st.sessions, session.id, session)}

  defp fetch_session(st, params) do
    case Map.fetch(st.sessions, params["sessionId"]) do
      {:ok, session} -> {:ok, session}
      :error -> {:error, "Unknown session: #{inspect(params["sessionId"])}"}
    end
  end

  defp fetch_cwd(%{"cwd" => cwd}) when is_binary(cwd) do
    if Path.type(cwd) == :absolute,
      do: {:ok, cwd},
      else: {:error, "`cwd` must be an absolute path"}
  end

  defp fetch_cwd(_), do: {:error, "`cwd` is required"}

  defp fetch_string(params, key) do
    case params[key] do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, "`#{key}` is required"}
    end
  end

  defp or_not_found({:ok, session}, _id), do: {:ok, session}
  defp or_not_found(:error, id), do: {:error, :not_found, "Session not found: #{id}"}

  # MCP servers that the client hands over. The manager starts them for this session's conversation
  # only, and `terminate/2` stops them. A server that cannot start is logged by the manager and skipped.
  defp apply_mcp_servers(session, servers) when is_list(servers) and servers != [] do
    if Application.get_env(:super_pi, :mcp_clients, true),
      do: SuperPi.MCP.Manager.add_servers(session.conversation_id, servers)

    :ok
  end

  defp apply_mcp_servers(_session, _servers), do: :ok

  defp auth_methods do
    if Auth.required?(),
      do: [
        %{
          "id" => "token",
          "name" => "Gateway token",
          "description" => "A token from SUPER_PI_GATEWAY_TOKEN, sent in `_meta.token`"
        }
      ],
      else: []
  end

  # The ClientFS needs to find this process from a conversation, and know what the client can do.
  defp register_fs(conv_id, st) do
    fs? = get_in(st.client_caps, ["fs", "readTextFile"]) == true

    if fs? and self() not in :pg.get_local_members(Broker.scope(), {:acp_fs, conv_id}) do
      :pg.join(Broker.scope(), {:acp_fs, conv_id}, self())
    end

    :ok
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp format_reason(reason), do: SuperPi.AI.Provider.format_error(reason)
end
