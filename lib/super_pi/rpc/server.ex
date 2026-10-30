defmodule SuperPi.RPC.Server do
  @moduledoc """
  Day-1 JSON-RPC 2.0 Server over TCP, Unix Domain Socket, and `stdio` (`REQ-RPC-01`..`REQ-RPC-05`, `REQ-PBT-07`).

  Exposes the complete `SuperPi.Durable` and `SuperPi.Conversation.Machine` harness to external
  clients (VS Code extensions, Neovim plugins, desktop apps, web frontends, and CLI wrappers).

  ## Supported JSON-RPC 2.0 Methods
  - `session.open` — Creates or opens a durable conversation (`%{conversation_id: id, seq: seq}`).
  - `session.submit` — Submits user input with `mode` (`"queue"`, `"steer"`, `"write"`).
  - `session.fork` — Forks a conversation at `at_entry_id` with `asOf` document rewind.
  - `session.compact` — Runs context compaction (`"manual"`, `"threshold"`, `"overflow"`).
  - `session.context` — Derives the active LLM context via the 10 normative rules.
  - `session.watch` — Subscribes the client connection to `session.event` notifications with
    bounded `K = 2` in-flight backpressure (`REQ-RPC-03`).
  - `session.ack` — Acknowledges receipt of a `session.event` batch (`batch_id`), advancing the
    client's `K = 2` flow-control window and flushing coalesced pending deltas (`REQ-RPC-04`).
  - `ui.respond` — Delivers the user's answer to a server-initiated `ui.request` prompt (`REQ-RPC-05`).
  """

  use GenServer

  alias SuperPi.Compaction
  alias SuperPi.Conversation.Machine
  alias SuperPi.Durable.{Context, Doc, Storage}
  alias SuperPi.Durable.Schemas.Conversation
  alias SuperPi.Plugins.Permissions
  alias SuperPi.Auth
  alias SuperPi.Repo

  @max_in_flight_batches 2
  @max_coalesced_queue 1_000

  defstruct [
    :listen_socket,
    :port,
    :socket_path,
    clients: %{}
  ]

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  def port(server_pid) do
    GenServer.call(server_pid, :port)
  end

  @doc """
  Processes a single raw JSON-RPC 2.0 line and returns `{reply_map | nil, updated_client_state, outbound_notifications}`.
  Pure state-transition function that is also used directly by `ExUnitProperties` (`REQ-PBT-07`).
  """
  def handle_rpc_payload(raw_json, client_state) when is_binary(raw_json) and is_map(client_state) do
    case Jason.decode(raw_json) do
      {:ok, %{"jsonrpc" => "2.0", "method" => method} = req} when is_binary(method) ->
        id = Map.get(req, "id")
        has_id? = Map.has_key?(req, "id")
        params = Map.get(req, "params")

        case validate_params(method, params) do
          :ok ->
            safe_params = if is_map(params), do: params, else: %{}

            case authorize(method, safe_params, client_state) do
              :ok ->
                {reply, next_state, notifs} = dispatch_method(method, safe_params, id, client_state)
                reply = if has_id?, do: reply, else: nil
                {reply, next_state, notifs}

              {:error, code, msg} ->
                reply = if has_id?, do: jsonrpc_error(id, code, msg), else: nil
                {reply, client_state, []}
            end

          {:error, code, msg} ->
            reply = if has_id?, do: jsonrpc_error(id, code, msg), else: nil
            {reply, client_state, []}
        end

      {:ok, _invalid} ->
        err = jsonrpc_error(nil, -32600, "Invalid Request")
        {err, client_state, []}

      {:error, _} ->
        err = jsonrpc_error(nil, -32700, "Parse error")
        {err, client_state, []}
    end
  end

  @doc """
  Enqueues a server-to-client `session.event` notification under the `K = 2` ack-clocked backpressure
  contract (`REQ-RPC-03`, `REQ-RPC-04`, `REQ-PBT-07`):
  - If `map_size(client_state.in_flight) < 2`, immediately emits a `session.event` JSON-RPC notification
    with a fresh `batch_id` and records `batch_id` in `in_flight`.
  - If `map_size(client_state.in_flight) >= 2`, coalesces `event_payload` into `client_state.coalesced_queue`
    without emitting any wire frame until the client calls `session.ack`.
  """
  def enqueue_watch_event(client_state, event_payload) when is_map(client_state) and is_map(event_payload) do
    in_flight = Map.get(client_state, :in_flight, %{})
    next_batch_id = Map.get(client_state, :next_batch_id, 1)

    if map_size(in_flight) < @max_in_flight_batches do
      notification = %{
        "jsonrpc" => "2.0",
        "method" => "session.event",
        "params" => %{
          "batch_id" => next_batch_id,
          "events" => [event_payload]
        }
      }

      updated =
        client_state
        |> Map.put(:in_flight, Map.put(in_flight, next_batch_id, [event_payload]))
        |> Map.put(:next_batch_id, next_batch_id + 1)

      {updated, [notification]}
    else
      queued = Map.get(client_state, :coalesced_queue, [])

      new_queue =
        if length(queued) >= @max_coalesced_queue do
          tl(queued) ++ [event_payload]
        else
          queued ++ [event_payload]
        end

      {Map.put(client_state, :coalesced_queue, new_queue), []}
    end
  end

  @doc """
  Processes a client `session.ack` for `batch_id` (`REQ-RPC-04`, `REQ-PBT-07`).
  Removes `batch_id` from `in_flight`; if `coalesced_queue` is non-empty and `map_size(in_flight) < 2`,
  flushes all coalesced events in a single consolidated `session.event` batch.
  """
  def ack_watch_batch(client_state, batch_id) when is_map(client_state) and is_integer(batch_id) do
    in_flight = Map.get(client_state, :in_flight, %{}) |> Map.delete(batch_id)
    coalesced = Map.get(client_state, :coalesced_queue, [])
    next_batch_id = Map.get(client_state, :next_batch_id, 1)

    if coalesced != [] and map_size(in_flight) < @max_in_flight_batches do
      notification = %{
        "jsonrpc" => "2.0",
        "method" => "session.event",
        "params" => %{
          "batch_id" => next_batch_id,
          "events" => coalesced
        }
      }

      updated =
        client_state
        |> Map.put(:in_flight, Map.put(in_flight, next_batch_id, coalesced))
        |> Map.put(:coalesced_queue, [])
        |> Map.put(:next_batch_id, next_batch_id + 1)

      {updated, [notification]}
    else
      {Map.put(client_state, :in_flight, in_flight), []}
    end
  end

  def new_client_state do
    %{
      # nil until `auth.login` succeeds when tokens are configured (`SuperPi.Auth`).
      principal: if(Auth.required?(), do: nil, else: Auth.anonymous()),
      watched_conversations: MapSet.new(),
      in_flight: %{},
      coalesced_queue: [],
      next_batch_id: 1,
      pending_ui_requests: %{}
    }
  end

  # --- GenServer Socket Listener ---

  @impl true
  def init(opts) do
    base = [:binary, packet: :line, active: false, buffer: 1_000_000, packet_size: 1_000_000]

    {listen_socket, actual_port, socket_path} =
      case Keyword.get(opts, :socket_path) do
        nil ->
          {:ok, sock} =
            :gen_tcp.listen(Keyword.get(opts, :port, 0), base ++ [reuseaddr: true, ip: {127, 0, 0, 1}])

          {:ok, actual_port} = :inet.port(sock)
          {sock, actual_port, nil}

        path ->
          # A Unix socket is reachable only by processes that can open the file.
          # Remove a stale file from an earlier run, and restrict the new one to the owner.
          File.rm(path)
          {:ok, sock} = :gen_tcp.listen(0, base ++ [ifaddr: {:local, to_charlist(path)}])
          File.chmod!(path, 0o600)
          {sock, nil, path}
      end

    server_pid = self()
    spawn_link(fn -> accept_loop(listen_socket, server_pid) end)

    {:ok, %__MODULE__{listen_socket: listen_socket, port: actual_port, socket_path: socket_path}}
  end

  @impl true
  def handle_call(:port, _from, %__MODULE__{} = state) do
    {:reply, state.port, state}
  end

  @impl true
  def terminate(_reason, %__MODULE__{listen_socket: sock, socket_path: path}) do
    if sock, do: :gen_tcp.close(sock)
    if path, do: File.rm(path)
    :ok
  end

  defp accept_loop(listen_socket, server_pid) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, client_sock} ->
        pid = spawn(fn -> serve_client_socket(client_sock, new_client_state()) end)
        :ok = :gen_tcp.controlling_process(client_sock, pid)
        send(pid, :socket_ready)
        accept_loop(listen_socket, server_pid)

      {:error, :closed} ->
        :ok

      {:error, _} ->
        :ok
    end
  end

  defp serve_client_socket(sock, client_state) do
    receive do
      :socket_ready ->
        rearm(sock)
        client_loop(sock, client_state, "")
    after
      5_000 ->
        :gen_tcp.close(sock)
    end
  end

  defp client_loop(sock, client_state, buf) do
    receive do
      {:tcp, ^sock, chunk} ->
        new_buf = buf <> chunk
        {lines, rem_buf} = split_lines(new_buf)
        next_state = process_lines(sock, lines, client_state)
        rearm(sock)
        client_loop(sock, next_state, rem_buf)

      {:async_rpc_reply, reply, notifs} ->
        if reply do
          send_line(sock, Jason.encode!(reply) <> "\n")
        end

        Enum.each(notifs, fn notif ->
          send_line(sock, Jason.encode!(notif) <> "\n")
        end)

        client_loop(sock, client_state, buf)

      {:conversation_event, conv_id, event_payload} ->
        if MapSet.member?(client_state.watched_conversations, conv_id) do
          {next_state, notifications} = enqueue_watch_event(client_state, event_payload)

          Enum.each(notifications, fn notif ->
            send_line(sock, Jason.encode!(notif) <> "\n")
          end)

          client_loop(sock, next_state, buf)
        else
          client_loop(sock, client_state, buf)
        end

      {:conversation_state, _conv_id, _status} ->
        client_loop(sock, client_state, buf)

      {:tcp_closed, ^sock} ->
        Enum.each(Map.get(client_state, :submit_tasks, []), fn pid ->
          Process.exit(pid, :kill)
        end)
        close_transport(sock)

      {:tcp_error, ^sock, _reason} ->
        Enum.each(Map.get(client_state, :submit_tasks, []), fn pid ->
          Process.exit(pid, :kill)
        end)
        close_transport(sock)
    end
  end

  defp split_lines(buf) do
    case String.split(buf, "\n") do
      [single] -> {[], single}
      lines -> {Enum.slice(lines, 0..-2//1), List.last(lines)}
    end
  end

  defp process_lines(_sock, [], client_state), do: client_state

  defp process_lines(sock, [raw_line | rest], client_state) do
    line = String.trim(raw_line)

    if line == "" do
      process_lines(sock, rest, client_state)
    else
      case Jason.decode(line) do
        {:ok, %{"method" => "session.submit"} = _req} ->
          parent = self()

          {:ok, task_pid} =
            Task.Supervisor.start_child(SuperPi.ToolTaskSupervisor, fn ->
              {reply, _st, notifs} = handle_rpc_payload(line, client_state)
              send(parent, {:async_rpc_reply, reply, notifs})
            end)

          updated_state = Map.update(client_state, :submit_tasks, [task_pid], &[task_pid | &1])
          process_lines(sock, rest, updated_state)

        _ ->
          {reply, next_state, notifications} = handle_rpc_payload(line, client_state)

          if reply do
            send_line(sock, Jason.encode!(reply) <> "\n")
          end

          Enum.each(notifications, fn notif ->
            send_line(sock, Jason.encode!(notif) <> "\n")
          end)

          process_lines(sock, rest, next_state)
      end
    end
  end

  # --- stdio transport ---

  @doc """
  Serves one client on standard input and output until stdin closes. One JSON-RPC message
  per line in each direction.

  stdout carries only protocol lines, so route logs to stderr first (`bin/super-pi rpc --stdio`
  does this with `SUPER_PI_LOG_STDERR=1`).
  """
  def run_stdio(opts \\ []) do
    parent = self()
    # Raw bytes by default, so UTF-8 JSON passes through unchanged. A test can inject a reader.
    read_line = Keyword.get(opts, :read_line, fn -> IO.binread(:stdio, :line) end)
    spawn_link(fn -> read_stdin(parent, read_line) end)
    client_loop(:stdio, new_client_state(), "")
  end

  defp read_stdin(parent, read_line) do
    case read_line.() do
      line when is_binary(line) ->
        send(parent, {:tcp, :stdio, line})
        read_stdin(parent, read_line)

      _eof_or_error ->
        send(parent, {:tcp_closed, :stdio})
    end
  end

  # `sock` is a socket, or `:stdio`. The client loop is the same for both.
  defp send_line(:stdio, data), do: IO.binwrite(:stdio, data)
  defp send_line(sock, data), do: :gen_tcp.send(sock, data)

  defp rearm(:stdio), do: :ok
  defp rearm(sock), do: :inet.setopts(sock, active: :once)

  defp close_transport(:stdio), do: :ok
  defp close_transport(sock), do: :gen_tcp.close(sock)

  # --- Method Parameter Validation ---

  defp validate_params("session.open", params) do
    cond do
      params != nil and not is_map(params) ->
        {:error, -32602, "Invalid params: params must be an object"}

      is_map(params) and Map.has_key?(params, "agent") and not is_map(params["agent"]) ->
        {:error, -32602, "Invalid params: agent must be an object"}

      is_map(params) and Map.has_key?(params, "conversation_id") and not is_integer(params["conversation_id"]) ->
        {:error, -32602, "Invalid params: conversation_id must be an integer"}

      true ->
        :ok
    end
  end

  defp validate_params("session.submit", params) do
    cond do
      not is_map(params) ->
        {:error, -32602, "Invalid params: params must be an object"}

      not is_integer(Map.get(params, "conversation_id")) ->
        {:error, -32602, "Invalid params: conversation_id must be an integer"}

      not is_binary(Map.get(params, "text")) ->
        {:error, -32602, "Invalid params: text must be a string"}

      true ->
        :ok
    end
  end

  defp validate_params("session.fork", params) do
    cond do
      not is_map(params) ->
        {:error, -32602, "Invalid params: params must be an object"}

      not is_integer(Map.get(params, "conversation_id")) ->
        {:error, -32602, "Invalid params: conversation_id must be an integer"}

      not is_integer(Map.get(params, "at_entry_id")) ->
        {:error, -32602, "Invalid params: at_entry_id must be an integer"}

      true ->
        :ok
    end
  end

  defp validate_params("session.compact", params) do
    cond do
      not is_map(params) ->
        {:error, -32602, "Invalid params: params must be an object"}

      not is_integer(Map.get(params, "conversation_id")) ->
        {:error, -32602, "Invalid params: conversation_id must be an integer"}

      true ->
        :ok
    end
  end

  defp validate_params("session.context", params) do
    cond do
      not is_map(params) ->
        {:error, -32602, "Invalid params: params must be an object"}

      not is_integer(Map.get(params, "conversation_id")) ->
        {:error, -32602, "Invalid params: conversation_id must be an integer"}

      true ->
        :ok
    end
  end

  defp validate_params("session.watch", params) do
    cond do
      not is_map(params) ->
        {:error, -32602, "Invalid params: params must be an object"}

      not is_integer(Map.get(params, "conversation_id")) ->
        {:error, -32602, "Invalid params: conversation_id must be an integer"}

      true ->
        :ok
    end
  end

  defp validate_params("session.ack", params) do
    cond do
      not is_map(params) ->
        {:error, -32602, "Invalid params: params must be an object"}

      not is_integer(Map.get(params, "batch_id")) ->
        {:error, -32602, "Invalid params: batch_id must be an integer"}

      true ->
        :ok
    end
  end

  defp validate_params("session.cancel", params) do
    cond do
      not is_map(params) ->
        {:error, -32602, "Invalid params: params must be an object"}

      not is_integer(Map.get(params, "conversation_id")) ->
        {:error, -32602, "Invalid params: conversation_id must be an integer"}

      true ->
        :ok
    end
  end

  defp validate_params("session.configure", params) do
    cond do
      not is_map(params) ->
        {:error, -32602, "Invalid params: params must be an object"}

      not is_integer(Map.get(params, "conversation_id")) ->
        {:error, -32602, "Invalid params: conversation_id must be an integer"}

      Map.has_key?(params, "agent") and not is_map(params["agent"]) ->
        {:error, -32602, "Invalid params: agent must be an object"}

      true ->
        :ok
    end
  end

  defp validate_params("ui.respond", params) do
    cond do
      not is_map(params) ->
        {:error, -32602, "Invalid params: params must be an object"}

      not Map.has_key?(params, "request_id") ->
        {:error, -32602, "Invalid params: request_id is required"}

      not Map.has_key?(params, "value") ->
        {:error, -32602, "Invalid params: value is required"}

      true ->
        :ok
    end
  end

  defp validate_params(_other, _params), do: :ok

  # --- Authentication and ownership ---

  # A client that has no `:principal` key (a hand-built state) is open only when no token is
  # configured. A conversation owned by another principal answers like a missing one.
  defp principal(client_state) do
    case Map.fetch(client_state, :principal) do
      {:ok, principal} -> principal
      :error -> if Auth.required?(), do: nil, else: Auth.anonymous()
    end
  end

  defp authorize("auth.login", _params, _client_state), do: :ok

  defp authorize(_method, params, client_state) do
    case principal(client_state) do
      nil ->
        {:error, -32001, "Unauthorized: call auth.login with a valid token first"}

      principal ->
        case Map.get(params, "conversation_id") do
          conv_id when is_integer(conv_id) ->
            if Auth.authorized?(conv_id, principal),
              do: :ok,
              else: {:error, -32004, "Conversation not found: #{conv_id}"}

          _ ->
            :ok
        end
    end
  end

  # --- Method Dispatch ---

  defp dispatch_method("auth.login", params, id, client_state) do
    case Auth.authenticate(Map.get(params, "token")) do
      {:ok, principal} ->
        {jsonrpc_result(id, %{"principal" => principal}), Map.put(client_state, :principal, principal), []}

      :error ->
        {jsonrpc_error(id, -32001, "Unauthorized: invalid token"), client_state, []}
    end
  end

  defp dispatch_method("session.open", params, id, client_state) do
    case fetch_harness(params) do
      {:ok, harness} -> open_session(harness, params, id, client_state)
      {:error, reason} -> {jsonrpc_error(id, -32602, "Unknown harness: #{inspect(reason)}"), client_state, []}
    end
  end

  defp dispatch_method("session.submit", params, id, client_state) do
    conv_id = Map.fetch!(params, "conversation_id")
    text = Map.fetch!(params, "text")
    mode_str = Map.get(params, "mode", "queue")
    mode = parse_submit_mode(mode_str)
    async? = Map.get(params, "async", false)
    extensions = resolve_extensions(params)

    pid = ensure_machine_started!(conv_id, extensions)

    if async? do
      Task.Supervisor.start_child(SuperPi.ToolTaskSupervisor, fn ->
        case safe_machine_submit(pid, text, mode: mode, timeout: 120_000) do
          {:ok, res} ->
            Phoenix.PubSub.broadcast(
              SuperPi.PubSub,
              "conversation:#{conv_id}",
              {:conversation_event, conv_id,
               %{
                 "type" => "turn_completed",
                 "conversation_id" => conv_id,
                 "result" => res,
                 "seq" => Storage.current_seq()
               }}
            )

          {:error, reason} ->
            Phoenix.PubSub.broadcast(
              SuperPi.PubSub,
              "conversation:#{conv_id}",
              {:conversation_event, conv_id,
               %{
                 "type" => "turn_error",
                 "conversation_id" => conv_id,
                 "error" => inspect(reason),
                 "seq" => Storage.current_seq()
               }}
            )
        end
      end)

      {jsonrpc_result(id, %{"status" => "accepted", "conversation_id" => conv_id, "seq" => Storage.current_seq()}),
       client_state, []}
    else
      case safe_machine_submit(pid, text, mode: mode, timeout: 120_000) do
        {:ok, res} ->
          {next_client, notifs} =
            if MapSet.member?(client_state.watched_conversations, conv_id) do
              enqueue_watch_event(client_state, %{
                "type" => "turn_completed",
                "conversation_id" => conv_id,
                "result" => res,
                "seq" => Storage.current_seq()
              })
            else
              {client_state, []}
            end

          {jsonrpc_result(id, %{"status" => "ok", "result" => res, "seq" => Storage.current_seq()}), next_client,
           notifs}

        {:error, reason} ->
          {jsonrpc_error(id, -32000, inspect(reason)), client_state, []}
      end
    end
  end

  defp dispatch_method("session.fork", params, id, client_state) do
    parent_id = Map.fetch!(params, "conversation_id")
    at_entry_id = Map.fetch!(params, "at_entry_id")
    fork_conv = Storage.fork_conversation!(parent_id, at_entry_id)
    Auth.claim!(fork_conv.id, principal(client_state) || Auth.anonymous())

    reply =
      jsonrpc_result(id, %{
        "conversation_id" => fork_conv.id,
        "parent_conversation_id" => parent_id,
        "parent_entry_id" => at_entry_id,
        "seq" => Storage.current_seq()
      })

    {reply, client_state, []}
  end

  defp dispatch_method("session.compact", params, id, client_state) do
    conv_id = Map.fetch!(params, "conversation_id")
    keep_tokens = Map.get(params, "keep_recent_tokens", 20_000)
    {:ok, res} = Compaction.compact!(conv_id, :manual, keep_recent_tokens: keep_tokens)

    reply =
      jsonrpc_result(id, %{
        "entry_id" => res.entry.id,
        "head_entry_id" => res.head_entry_id,
        "compacted_count" => res.compacted_count,
        "kept_count" => res.kept_count,
        "summary" => res.summary
      })

    {reply, client_state, []}
  end

  defp dispatch_method("session.context", params, id, client_state) do
    conv_id = Map.fetch!(params, "conversation_id")
    derived = Context.derive(conv_id)

    reply =
      jsonrpc_result(id, %{
        "conversation_id" => conv_id,
        "messages" => derived.messages,
        "system_sections" => derived.system_sections,
        "tools" => derived.tools
      })

    {reply, client_state, []}
  end

  defp dispatch_method("session.watch", params, id, client_state) do
    conv_id = Map.fetch!(params, "conversation_id")

    if not MapSet.member?(client_state.watched_conversations, conv_id) do
      Phoenix.PubSub.subscribe(SuperPi.PubSub, "conversation:#{conv_id}")
    end

    watched = MapSet.put(client_state.watched_conversations, conv_id)
    next_state = Map.put(client_state, :watched_conversations, watched)

    {next_state, notifs} =
      enqueue_watch_event(next_state, %{
        "type" => "watch_started",
        "conversation_id" => conv_id,
        "seq" => Storage.current_seq()
      })

    {jsonrpc_result(id, %{"watching" => conv_id, "max_in_flight" => @max_in_flight_batches}), next_state, notifs}
  end

  defp dispatch_method("session.ack", params, id, client_state) do
    batch_id = Map.fetch!(params, "batch_id")
    {next_state, notifs} = ack_watch_batch(client_state, batch_id)
    reply = if id, do: jsonrpc_result(id, %{"acked" => batch_id}), else: nil
    {reply, next_state, notifs}
  end

  defp dispatch_method("ui.respond", params, id, client_state) do
    req_id = Map.fetch!(params, "request_id")
    value = Map.get(params, "value")
    pending = Map.put(client_state.pending_ui_requests, req_id, value)
    next_state = Map.put(client_state, :pending_ui_requests, pending)
    {jsonrpc_result(id, %{"resolved" => req_id, "value" => value}), next_state, []}
  end

  defp dispatch_method("session.cancel", params, id, client_state) do
    conv_id = Map.fetch!(params, "conversation_id")

    case Registry.lookup(SuperPi.Registry, {:conversation_machine, conv_id}) do
      [{pid, _}] ->
        try do
          Machine.cancel(pid)
        catch
          :exit, _ -> :ok
        end

      [] ->
        :ok
    end

    Phoenix.PubSub.broadcast(
      SuperPi.PubSub,
      "conversation:#{conv_id}",
      {:conversation_event, conv_id,
       %{
         "type" => "turn_cancelled",
         "conversation_id" => conv_id,
         "seq" => Storage.current_seq()
       }}
    )

    {jsonrpc_result(id, %{"cancelled" => conv_id, "status" => "ok"}), client_state, []}
  end

  defp dispatch_method("session.configure", params, id, client_state) do
    conv_id = Map.fetch!(params, "conversation_id")
    patch = params |> Map.get("agent", %{}) |> sanitize_agent_param()
    Storage.configure_agent!(conv_id, patch)
    updated = Doc.snapshot("conversation", conv_id, "pi.agent")

    {jsonrpc_result(id, %{"conversation_id" => conv_id, "agent" => updated, "seq" => Storage.current_seq()}),
     client_state, []}
  end

  defp dispatch_method(method, _params, id, client_state) when method in ["workspace.metadata", "metadata"] do
    reply =
      jsonrpc_result(id, %{
        "models" => SuperPi.CLI.models_catalog(),
        "agents" => SuperPi.CLI.agents_catalog(),
        "slash_commands" => [
          %{"name" => "/plan", "description" => "Switch to read-only architectural planning mode"},
          %{"name" => "/goal", "description" => "Run autonomous multi-step goal with verification"},
          %{"name" => "/boost", "description" => "Maximize reasoning effort (effort=max)"},
          %{"name" => "/compact", "description" => "Compact conversation context"},
          %{"name" => "/model", "description" => "Switch active LLM model (/model <name>)"},
          %{"name" => "/mode", "description" => "Switch execution mode (/mode auto|plan|accept-edits)"},
          %{"name" => "/fork", "description" => "Fork current conversation branch"},
          %{"name" => "/help", "description" => "Display keyboard shortcuts and slash commands"}
        ]
      })

    {reply, client_state, []}
  end

  defp dispatch_method(unknown, _params, id, client_state) do
    {jsonrpc_error(id, -32601, "Method not found: #{unknown}"), client_state, []}
  end

  defp parse_submit_mode("steer"), do: :steer
  defp parse_submit_mode("write"), do: :write
  defp parse_submit_mode(_), do: :queue

  defp safe_machine_submit(pid, text, opts) do
    try do
      Machine.submit(pid, text, opts)
    catch
      :exit, reason ->
        {:error, reason}
    end
  end

  defp ensure_machine_started!(conv_id, extensions) do
    case Registry.lookup(SuperPi.Registry, {:conversation_machine, conv_id}) do
      [{pid, _}] ->
        pid

      [] ->
        case Process.whereis(SuperPi.MachineSupervisor) do
          nil ->
            {:ok, pid} = Machine.start_link(conversation_id: conv_id, extensions: extensions)
            pid

          _sup ->
            case DynamicSupervisor.start_child(SuperPi.MachineSupervisor, {Machine, conversation_id: conv_id, extensions: extensions}) do
              {:ok, pid} -> pid
              {:error, {:already_started, pid}} -> pid
            end
        end
    end
  end

  defp open_session(harness, params, id, client_state) do
    conv =
      case Map.get(params, "conversation_id") do
        nil ->
          base_agent = Permissions.sanitize_remote_agent(Map.get(params, "agent", %{}))

          model_opts = if model = Map.get(base_agent, "model"), do: [model: model], else: []

          defaults =
            harness.agent_defaults(model_opts)
            |> Permissions.apply_remote_mode(Map.get(base_agent, "executionMode"))

          agent_cfg = Map.merge(defaults, base_agent)
          conv = Storage.create_conversation!(agent: agent_cfg)
          Auth.claim!(conv.id, principal(client_state) || Auth.anonymous())
          conv

        conv_id ->
          if Map.has_key?(params, "agent") do
            user_agent = params |> Map.get("agent") |> sanitize_agent_param()

            if is_map(user_agent) and map_size(user_agent) > 0 do
              Storage.configure_agent!(conv_id, user_agent)
            end
          end

          Repo.get!(Conversation, conv_id)
      end

    extensions = harness.extensions([])
    ensure_machine_started!(conv.id, extensions)

    reply =
      jsonrpc_result(id, %{
        "conversation_id" => conv.id,
        "seq" => Storage.current_seq(),
        "agent" => Doc.snapshot("conversation", conv.id, "pi.agent")
      })

    {reply, client_state, []}
  end

  defp resolve_extensions(params) do
    case fetch_harness(params) do
      {:ok, harness} -> harness.extensions([])
      {:error, _} -> SuperPi.Harness.default().extensions([])
    end
  end

  # An explicit harness name must exist. With no name, the configured default harness applies.
  defp fetch_harness(params) do
    case Map.get(params, "harness") || Map.get(params, "preset") do
      nil ->
        model = Map.get(params, "model")

        if is_binary(model) and SuperPi.Harness.harness?(model),
          do: {:ok, SuperPi.Harness.resolve(model)},
          else: {:ok, SuperPi.Harness.default()}

      key ->
        SuperPi.Harness.fetch(key)
    end
  end

  defp sanitize_agent_param(agent) when is_map(agent), do: Permissions.sanitize_remote_agent(agent)
  defp sanitize_agent_param(other), do: other

  defp jsonrpc_result(id, result) do
    %{"jsonrpc" => "2.0", "id" => id, "result" => result}
  end

  defp jsonrpc_error(id, code, message) do
    %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}
  end
end
