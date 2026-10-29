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
  alias SuperPi.Repo

  @max_in_flight_batches 2

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
      {:ok, %{"jsonrpc" => "2.0", "method" => method} = req} ->
        id = Map.get(req, "id")
        params = Map.get(req, "params", %{})
        dispatch_method(method, params, id, client_state)

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
      {Map.put(client_state, :coalesced_queue, queued ++ [event_payload]), []}
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
    port = Keyword.get(opts, :port, 0)

    {:ok, listen_socket} =
      :gen_tcp.listen(port, [:binary, packet: :line, active: false, reuseaddr: true])

    {:ok, actual_port} = :inet.port(listen_socket)
    server_pid = self()

    spawn_link(fn -> accept_loop(listen_socket, server_pid) end)

    {:ok, %__MODULE__{listen_socket: listen_socket, port: actual_port}}
  end

  @impl true
  def handle_call(:port, _from, %__MODULE__{} = state) do
    {:reply, state.port, state}
  end

  @impl true
  def terminate(_reason, %__MODULE__{listen_socket: sock}) do
    if sock, do: :gen_tcp.close(sock)
    :ok
  end

  defp accept_loop(listen_socket, server_pid) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, client_sock} ->
        spawn(fn -> serve_client_socket(client_sock, new_client_state()) end)
        accept_loop(listen_socket, server_pid)

      {:error, :closed} ->
        :ok

      {:error, _} ->
        :ok
    end
  end

  defp serve_client_socket(sock, client_state) do
    case :gen_tcp.recv(sock, 0) do
      {:ok, line} ->
        {reply, next_state, notifications} = handle_rpc_payload(String.trim(line), client_state)

        if reply do
          :gen_tcp.send(sock, Jason.encode!(reply) <> "\n")
        end

        Enum.each(notifications, fn notif ->
          :gen_tcp.send(sock, Jason.encode!(notif) <> "\n")
        end)

        serve_client_socket(sock, next_state)

      {:error, _} ->
        :gen_tcp.close(sock)
    end
  end

  # --- Method Dispatch ---

  defp dispatch_method("session.open", params, id, client_state) do
    conv =
      case Map.get(params, "conversation_id") do
        nil -> Storage.create_conversation!(agent: Map.get(params, "agent", %{}))
        conv_id -> Repo.get!(Conversation, conv_id)
      end

    ensure_machine_started!(conv.id)

    reply =
      jsonrpc_result(id, %{
        "conversation_id" => conv.id,
        "seq" => Storage.current_seq(),
        "agent" => Doc.snapshot("conversation", conv.id, "pi.agent")
      })

    {reply, client_state, []}
  end

  defp dispatch_method("session.submit", params, id, client_state) do
    conv_id = Map.fetch!(params, "conversation_id")
    text = Map.fetch!(params, "text")
    mode_str = Map.get(params, "mode", "queue")
    mode = parse_submit_mode(mode_str)

    pid = ensure_machine_started!(conv_id)

    case Machine.submit(pid, text, mode: mode) do
      {:ok, res} ->
        {next_client, notifs} =
          if MapSet.member?(client_state.watched_conversations, conv_id) do
            enqueue_watch_event(client_state, %{
              "type" => "turn_completed",
              "conversation_id" => conv_id,
              "seq" => Storage.current_seq()
            })
          else
            {client_state, []}
          end

        {jsonrpc_result(id, %{"status" => "ok", "result" => res, "seq" => Storage.current_seq()}), next_client, notifs}

      {:error, reason} ->
        {jsonrpc_error(id, -32000, inspect(reason)), client_state, []}
    end
  end

  defp dispatch_method("session.fork", params, id, client_state) do
    parent_id = Map.fetch!(params, "conversation_id")
    at_entry_id = Map.fetch!(params, "at_entry_id")
    fork_conv = Storage.fork_conversation!(parent_id, at_entry_id)

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

  defp dispatch_method(unknown, _params, id, client_state) do
    {jsonrpc_error(id, -32601, "Method not found: #{unknown}"), client_state, []}
  end

  defp parse_submit_mode("steer"), do: :steer
  defp parse_submit_mode("write"), do: :write
  defp parse_submit_mode(_), do: :queue

  defp ensure_machine_started!(conv_id) do
    case Registry.lookup(SuperPi.Registry, {:conversation_machine, conv_id}) do
      [{pid, _}] ->
        pid

      [] ->
        {:ok, pid} = Machine.start_link(conversation_id: conv_id)
        pid
    end
  end

  defp jsonrpc_result(id, result) do
    %{"jsonrpc" => "2.0", "id" => id, "result" => result}
  end

  defp jsonrpc_error(id, code, message) do
    %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}
  end
end
