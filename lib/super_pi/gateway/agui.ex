defmodule SuperPi.Gateway.AGUI do
  @moduledoc """
  [AG-UI](https://docs.ag-ui.com) over Server-Sent Events, forwarded from `SuperPi.Gateway.Router`
  at `/agui/v1`. The router's `authenticate`, `reject_when_draining` and `trace_request` plugs
  already ran, so this module has no auth of its own.

  | Route | Does |
  |---|---|
  | `POST /agui/v1/run` | Body is a `RunAgentInput` (`threadId`, `runId`, `messages`, `forwardedProps`). Opens the SSE response, submits the last user message and streams the run until it ends. This is the shape that `@ag-ui/client`'s `HttpAgent` expects. |
  | `GET /agui/v1/sessions/:id/events` | Attaches to a live conversation. Sends `STATE_SNAPSHOT` and `MESSAGES_SNAPSHOT`, then live events. Keeps the stream open with a comment line every 15 s. |
  | `POST /agui/v1/sessions/:id/input` | Sends input into a conversation: `{"type": "prompt", "text": ...}`, `{"type": "permission", "request_id": ..., "option_id": ...}`, `{"type": "answer", "request_id": ..., "value": ...}` or `{"type": "cancel"}`. |

  `threadId` maps to a conversation through `SuperPi.Gateway.Sessions` (as `agui:<threadId>`, per
  principal). `forwardedProps` may carry `harness` and `executionMode`. A remote mode never goes
  above `Permissions.remote_mode/1`.

  ## Resuming

  After a disconnect, `GET .../events` sends a fresh `STATE_SNAPSHOT` and `MESSAGES_SNAPSHOT`. The
  snapshot covers whatever was lost in the gap. Exact replay would need a database write per
  `text_delta` or an append-only event table, which the snapshot events exist to avoid.

  ## Backpressure

  There is no ack window (the RPC server has one because the client can call `session.ack`). SSE is
  one-way and TCP is the backpressure: a failed chunk write cancels the turn. Deltas that arrive within
  16 ms are merged into one content event (`SuperPi.Event.Renderer.AGUI.coalesce/1`).

  ## Prompts

  A `permission_request` and a `ui_request` arrive as `CUSTOM` events. The client answers with
  `POST .../input` of type `permission` or `answer`. The stream registers as an interactive responder,
  so `Permissions` asks instead of blocking. With `?interactive=false` on `/run` the stream does not
  register, and `Permissions` blocks as for any other Gateway client.
  """

  use Plug.Router

  alias SuperPi.Auth
  alias SuperPi.Conversation.Machine
  alias SuperPi.Durable.{Doc, Storage}
  alias SuperPi.Event
  alias SuperPi.Event.{History, Renderer}
  alias SuperPi.Gateway.Sessions
  alias SuperPi.Harness
  alias SuperPi.Plugins.Permissions
  alias SuperPi.UI.Broker

  @batch_ms 16
  @keepalive_ms 15_000
  @run_timeout_ms 300_000

  plug :match
  plug :dispatch

  post "/run" do
    params = conn.body_params
    principal = conn.assigns[:principal] || Auth.anonymous()

    with {:ok, thread_id} <- fetch_string(params, "threadId"),
         {:ok, prompt} <- last_user_text(params["messages"]),
         {:ok, harness} <- pick_harness(conn, params) do
      {conv_id, new?} =
        Sessions.fetch_or_create(principal, "agui:" <> thread_id, fn -> Storage.create_conversation!(agent: %{}, owner: principal) end)

      configure(conv_id, new?, harness, params)
      if new?, do: seed(conv_id, params["messages"])

      pid = SuperPi.Conversation.Locator.ensure_started!(conv_id, Harness.remote_extensions(harness), set_extensions: true)
      if conn.query_params["interactive"] != "false", do: Broker.register_responder(conv_id)

      stream_run(conn, conv_id, pid, prompt, thread_id, to_string(params["runId"] || ""))
    else
      {:error, message} -> json(conn, 400, %{"error" => %{"message" => message, "type" => "invalid_request_error"}})
    end
  end

  get "/sessions/:id/events" do
    with {:ok, conv_id} <- authorized_conversation(conn, id) do
      Broker.register_responder(conv_id)
      attach(conn, conv_id)
    else
      {:error, status, message} -> json(conn, status, %{"error" => %{"message" => message}})
    end
  end

  post "/sessions/:id/input" do
    with {:ok, conv_id} <- authorized_conversation(conn, id) do
      handle_input(conn, conv_id, conn.body_params)
    else
      {:error, status, message} -> json(conn, status, %{"error" => %{"message" => message}})
    end
  end

  match _ do
    json(conn, 404, %{"error" => %{"message" => "Endpoint not found: #{conn.request_path}", "type" => "invalid_request_error"}})
  end

  # --- Run ---

  defp stream_run(conn, conv_id, pid, prompt, thread_id, run_id) do
    Phoenix.PubSub.unsubscribe(SuperPi.PubSub, Event.topic(conv_id))
    Phoenix.PubSub.subscribe(SuperPi.PubSub, Event.topic(conv_id))

    otel_ctx = SuperPi.Telemetry.current_ctx()
    conn = start_sse(conn)

    rstate =
      Renderer.AGUI.init(
        thread_id: thread_id,
        run_id: if(run_id == "", do: nil, else: run_id),
        projection: Renderer.AGUI.initial_projection(conv_id),
        messages_fun: fn -> History.agui_messages(conv_id) end
      )

    {snapshot, rstate} = Renderer.AGUI.snapshot(rstate)

    case send_items(conn, snapshot) do
      {:ok, conn} ->
        task =
          Task.Supervisor.async_nolink(SuperPi.ToolTaskSupervisor, fn ->
            Machine.safe_submit(pid, prompt, mode: :queue, timeout: @run_timeout_ms, otel_ctx: otel_ctx)
          end)

        try do
          run_loop(conn, conv_id, pid, task.ref, rstate)
        after
          Phoenix.PubSub.unsubscribe(SuperPi.PubSub, Event.topic(conv_id))
          flush_mailbox(conv_id)
        end

      :error ->
        conn
    end
  end

  defp run_loop(conn, conv_id, pid, ref, rstate) do
    receive do
      {:conversation_event, ^conv_id, %{} = wire} ->
        events = [wire | collect_batch(conv_id, [])]
        {items, rstate, ended?} = render_batch(events, rstate)

        case send_items(conn, items) do
          {:ok, conn} when ended? -> conn
          {:ok, conn} -> run_loop(conn, conv_id, pid, ref, rstate)
          :error -> cancel(conv_id, pid, conn)
        end

      {^ref, {:error, reason}} ->
        Process.demonitor(ref, [:flush])
        # A machine that died publishes nothing. If the turn already ended there is nothing to add.
        if turn_over?(conv_id), do: conn, else: finish_with_error(conn, rstate, "Run failed: #{inspect(reason)}")

      {^ref, {:ok, _}} ->
        Process.demonitor(ref, [:flush])
        # The turn events are in the mailbox before the reply. Render what is left.
        finish_remaining(conn, conv_id, rstate)

      {:DOWN, ^ref, :process, _pid, reason} ->
        finish_with_error(conn, rstate, "Run worker crashed: #{inspect(reason)}")
    after
      @run_timeout_ms -> finish_with_error(conn, rstate, "The run timed out.")
    end
  end

  defp finish_remaining(conn, conv_id, rstate) do
    events = collect_batch(conv_id, [])
    {items, rstate, _ended?} = render_batch(events, rstate)
    {tail, _} = Renderer.AGUI.flush(rstate)

    case send_items(conn, items ++ tail) do
      {:ok, conn} -> conn
      :error -> conn
    end
  end

  defp finish_with_error(conn, rstate, message) do
    {items, _} = Renderer.AGUI.render(Event.from_wire(%{"type" => "turn_error", "error" => message}), rstate)

    case send_items(conn, items) do
      {:ok, conn} -> conn
      :error -> conn
    end
  end

  defp turn_over?(conv_id) do
    receive do
      {:conversation_event, ^conv_id, %{"type" => type}} when type in ["turn_completed", "turn_error", "turn_cancelled"] -> true
    after
      0 -> false
    end
  end

  defp cancel(conv_id, pid, conn) do
    Broker.cancel_pending(conv_id)
    Machine.cancel(pid)
    conn
  end

  # --- Attach ---

  defp attach(conn, conv_id) do
    Phoenix.PubSub.unsubscribe(SuperPi.PubSub, Event.topic(conv_id))
    Phoenix.PubSub.subscribe(SuperPi.PubSub, Event.topic(conv_id))
    conn = start_sse(conn)

    rstate =
      Renderer.AGUI.init(
        thread_id: to_string(conv_id),
        projection: Renderer.AGUI.initial_projection(conv_id),
        messages_fun: fn -> History.agui_messages(conv_id) end
      )

    {snapshot, rstate} = Renderer.AGUI.snapshot(rstate)

    messages = %{"type" => "MESSAGES_SNAPSHOT", "messages" => History.agui_messages(conv_id), "timestamp" => System.system_time(:millisecond)}

    try do
      case send_items(conn, snapshot ++ [messages]) do
        {:ok, conn} -> attach_loop(conn, conv_id, rstate)
        :error -> conn
      end
    after
      Phoenix.PubSub.unsubscribe(SuperPi.PubSub, Event.topic(conv_id))
      flush_mailbox(conv_id)
    end
  end

  defp attach_loop(conn, conv_id, rstate) do
    receive do
      {:conversation_event, ^conv_id, %{} = wire} ->
        events = [wire | collect_batch(conv_id, [])]
        {items, rstate, _ended?} = render_batch(events, rstate)

        case send_items(conn, items) do
          {:ok, conn} -> attach_loop(conn, conv_id, rstate)
          :error -> conn
        end
    after
      @keepalive_ms ->
        case chunk(conn, ": keepalive\n\n") do
          {:ok, conn} -> attach_loop(conn, conv_id, rstate)
          {:error, _} -> conn
        end
    end
  end

  # --- Input ---

  defp handle_input(conn, conv_id, %{"type" => "prompt", "text" => text}) when is_binary(text) and text != "" do
    pid = SuperPi.Conversation.Locator.ensure_started!(conv_id, Harness.remote_extensions(Harness.default()))
    Task.Supervisor.start_child(SuperPi.ToolTaskSupervisor, fn -> Machine.safe_submit(pid, text, mode: :queue, timeout: @run_timeout_ms) end)
    json(conn, 202, %{"status" => "accepted"})
  end

  defp handle_input(conn, conv_id, %{"type" => "permission", "request_id" => rid} = body) when is_binary(rid) do
    answer(conn, conv_id, rid, body["option_id"] || body["optionId"])
  end

  defp handle_input(conn, conv_id, %{"type" => "answer", "request_id" => rid} = body) when is_binary(rid) do
    answer(conn, conv_id, rid, body["value"])
  end

  defp handle_input(conn, conv_id, %{"type" => "cancel"}) do
    Broker.cancel_pending(conv_id)

    case SuperPi.Conversation.Locator.whereis(conv_id) do
      pid when is_pid(pid) -> Machine.cancel(pid)
      nil -> :ok
    end

    json(conn, 200, %{"status" => "cancelled"})
  end

  defp handle_input(conn, _conv_id, _body), do: json(conn, 400, %{"error" => %{"message" => "Unknown input. Use type prompt, permission, answer or cancel."}})

  defp answer(conn, conv_id, request_id, value) do
    # A request id answers only inside its own conversation.
    if Broker.conversation_of(request_id) == conv_id do
      Broker.respond(request_id, value)
      json(conn, 200, %{"status" => "resolved"})
    else
      json(conn, 404, %{"error" => %{"message" => "No request is waiting under #{request_id}"}})
    end
  end

  # --- Helpers ---

  defp render_batch(wires, rstate) do
    {items, rstate, ended?} =
      Enum.reduce(wires, {[], rstate, false}, fn wire, {acc, st, ended?} ->
        {out, st} = Renderer.AGUI.render(Event.from_wire(wire), st)
        {acc ++ out, st, ended? or wire["type"] in ["turn_completed", "turn_error", "turn_cancelled"]}
      end)

    {Renderer.AGUI.coalesce(items), rstate, ended?}
  end

  # Takes the events that arrive in the next few ms, so a burst of deltas becomes one content event.
  defp collect_batch(conv_id, acc) do
    receive do
      {:conversation_event, ^conv_id, %{} = wire} -> collect_batch(conv_id, [wire | acc])
    after
      @batch_ms -> Enum.reverse(acc)
    end
  end

  defp flush_mailbox(conv_id) do
    receive do
      {:conversation_event, ^conv_id, _} -> flush_mailbox(conv_id)
      {:conversation_state, ^conv_id, _} -> flush_mailbox(conv_id)
    after
      0 -> :ok
    end
  end

  defp start_sse(conn) do
    conn
    |> put_resp_header("content-type", "text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> put_resp_header("connection", "keep-alive")
    |> put_resp_header("x-accel-buffering", "no")
    |> send_chunked(200)
  end

  defp send_items(conn, items) do
    Enum.reduce_while(items, {:ok, conn}, fn item, {:ok, c} ->
      case chunk(c, "data: " <> Jason.encode!(item) <> "\n\n") do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _} -> {:halt, :error}
      end
    end)
  end

  defp fetch_string(params, key) do
    case params[key] do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, "`#{key}` is required"}
    end
  end

  defp last_user_text(messages) when is_list(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find(&(is_map(&1) and &1["role"] == "user"))
    |> case do
      %{"content" => c} when is_binary(c) and c != "" -> {:ok, c}
      %{"content" => parts} when is_list(parts) -> {:ok, parts |> Enum.map(&(is_map(&1) && &1["text"] || "")) |> Enum.join("")}
      _ -> {:error, "`messages` needs a user message"}
    end
  end

  defp last_user_text(_), do: {:error, "`messages` is required"}

  defp pick_harness(conn, params) do
    name =
      get_in(params, ["forwardedProps", "harness"]) ||
        case get_req_header(conn, "x-super-pi-harness") do
          [h | _] -> h
          [] -> nil
        end

    if name do
      case Harness.fetch(name) do
        {:ok, mod} -> {:ok, mod}
        {:error, _} -> {:error, "Unknown harness: #{name}"}
      end
    else
      {:ok, Harness.default()}
    end
  end

  defp configure(conv_id, new?, harness, params) do
    requested = get_in(params, ["forwardedProps", "executionMode"])
    agent = harness.agent_defaults() |> Permissions.apply_remote_mode(requested)
    if new?, do: Storage.configure_agent!(conv_id, agent)
  end

  # A thread that starts with history gets the earlier text messages as its past.
  defp seed(conv_id, messages) when is_list(messages) do
    messages
    |> Enum.drop(-1)
    |> Enum.each(fn
      %{"role" => role, "content" => text} when role in ["user", "assistant"] and is_binary(text) and text != "" ->
        Storage.append_entry!(conv_id, "pi.message", %{"role" => role, "content" => [%{"type" => "text", "text" => text}]})

      _ ->
        :ok
    end)
  end

  defp seed(_conv_id, _messages), do: :ok

  defp authorized_conversation(conn, raw_id) do
    principal = conn.assigns[:principal] || Auth.anonymous()

    case Integer.parse(raw_id) do
      {id, ""} ->
        if Doc.snapshot("conversation", id, "pi.agent") != nil and Auth.authorized?(id, principal),
          do: {:ok, id},
          else: {:error, 404, "Conversation not found: #{raw_id}"}

      _ ->
        {:error, 404, "Conversation not found: #{raw_id}"}
    end
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
