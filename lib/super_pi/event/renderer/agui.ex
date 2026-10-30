defmodule SuperPi.Event.Renderer.AGUI do
  @moduledoc """
  Renders events as [AG-UI](https://docs.ag-ui.com) events, for `SuperPi.Gateway.AGUI`.

  Each output item is a map with a `"type"` (`RUN_STARTED`, `TEXT_MESSAGE_CONTENT`, ...) and the
  fields of that event in camelCase, ready for `Jason.encode!/1` and an SSE `data:` line.

  ## Mapping

  | Event | AG-UI |
  |---|---|
  | `turn_started` | `RUN_STARTED` |
  | `text_delta` | `TEXT_MESSAGE_START` (once per message), `TEXT_MESSAGE_CONTENT` |
  | `thinking_delta` | `REASONING_START`, `REASONING_MESSAGE_START`, `REASONING_MESSAGE_CONTENT` |
  | `message_completed` | `TEXT_MESSAGE_END` (and the reasoning end events) |
  | `toolcall_delta` | `TOOL_CALL_START` (once per call), `TOOL_CALL_ARGS` |
  | `tool_started` | `TOOL_CALL_END` - AG-UI means *arguments complete* by it, not *tool complete* |
  | `tool_completed`, `tool_blocked` | `TOOL_CALL_RESULT` |
  | `turn_completed` | `RUN_FINISHED` |
  | `turn_error` | `RUN_ERROR` |
  | `turn_cancelled` | `RUN_ERROR` with `code` `"cancelled"` (AG-UI has no cancel event) |
  | `compaction_completed` | `MESSAGES_SNAPSHOT`, because the context really changed |
  | `state_changed`, `mode_changed`, `usage_updated`, `plan_updated`, `permission_request`, `ui_resolved` | `STATE_DELTA` |
  | `permission_request`, `ui_request`, `ui_resolved`, `notice`, `stream_reset`, `subagent_*` | `CUSTOM` |

  A bare run of deltas gets its `TEXT_MESSAGE_START` and `TEXT_MESSAGE_END` here, because the machine
  only emits deltas. A tool call that a provider did not stream gets `TOOL_CALL_START`,
  `TOOL_CALL_ARGS` and `TOOL_CALL_END` together when `tool_started` arrives.

  ## State

  The renderer keeps a small projection of the conversation (`status`, `mode`, `model`, `usage`,
  `plan`, `pendingPermission`). `snapshot/1` gives `STATE_SNAPSHOT` for an opening or a reconnect.
  After a state event it recomputes the projection and emits `STATE_DELTA` with
  `Jsonpatch.diff(previous, next)`. The durable document layer offers no patch stream for this: only
  `pi.agent` keeps ops, `pi.live` and `pi.usage` do not, and no write broadcasts. Doing it here is
  correct by construction and needs no change to document retention.

  ## Options

  - `:thread_id`, `:run_id` - ids of the run. `run_id` defaults to the turn id.
  - `:projection` - initial projection (`initial_projection/1` builds one from the documents).
  - `:messages_fun` - zero-arity function that returns the messages for `MESSAGES_SNAPSHOT`.

  ## Coalescing

  `coalesce/1` merges consecutive `TEXT_MESSAGE_CONTENT` and `TOOL_CALL_ARGS` items of the same
  message or call. The transport calls it on the batch of events that arrived within about 16 ms.
  There is no ack window as in the RPC server: SSE is one-way and TCP is the backpressure.
  """
  @behaviour SuperPi.Event.Renderer

  alias SuperPi.Durable.Doc
  alias SuperPi.Event

  defstruct thread_id: nil,
            run_id: nil,
            messages_fun: nil,
            message: nil,
            reasoning: nil,
            calls: %{},
            call_order: [],
            seq: 0,
            projection: %{},
            sent: %{}

  @impl true
  def init(opts) do
    projection = Keyword.get(opts, :projection, %{})

    %__MODULE__{
      thread_id: Keyword.get(opts, :thread_id),
      run_id: Keyword.get(opts, :run_id),
      messages_fun: Keyword.get(opts, :messages_fun),
      projection: projection,
      sent: projection
    }
  end

  @doc "The projection of a conversation, read from its documents."
  @spec initial_projection(integer()) :: map()
  def initial_projection(conversation_id) do
    live = Doc.snapshot("conversation", conversation_id, "pi.live") || %{}
    agent = Doc.snapshot("conversation", conversation_id, "pi.agent") || %{}
    usage = Doc.snapshot("conversation", conversation_id, "pi.usage") || %{}

    %{
      "status" => Map.get(live, "status", "idle"),
      "mode" => Map.get(agent, "executionMode"),
      "maxMode" => Map.get(agent, "maxExecutionMode"),
      "model" => Map.get(agent, "model"),
      "usage" => %{"inputTokens" => Map.get(usage, "inputTokens", 0), "outputTokens" => Map.get(usage, "outputTokens", 0)},
      "plan" => Enum.map(Map.get(live, "todos", []), &%{"id" => &1["id"], "text" => &1["text"], "completed" => &1["done"] == true}),
      "pendingPermission" => nil
    }
  end

  @doc "`STATE_SNAPSHOT` of the current projection. Marks it as sent, so the next delta is relative to it."
  @spec snapshot(%__MODULE__{}) :: {[map()], %__MODULE__{}}
  def snapshot(%__MODULE__{} = st) do
    {[item("STATE_SNAPSHOT", %{"snapshot" => st.projection})], %{st | sent: st.projection}}
  end

  @impl true
  def render(%Event{type: "turn_started"} = ev, st) do
    run_id = st.run_id || to_string(ev.turn_id)
    {[item("RUN_STARTED", %{"threadId" => st.thread_id, "runId" => run_id})], %{st | run_id: run_id}}
  end

  def render(%Event{type: "text_delta", data: %{"delta" => delta}} = ev, st) do
    {closing, st} = close_reasoning(st)
    {opening, st} = open_message(st, ev)
    {closing ++ opening ++ [item("TEXT_MESSAGE_CONTENT", %{"messageId" => st.message, "delta" => delta})], st}
  end

  def render(%Event{type: "thinking_delta", data: %{"delta" => delta}} = ev, st) do
    {opening, st} =
      if st.reasoning do
        {[], st}
      else
        {id, st} = next_id(st, ev, "reason")

        {[item("REASONING_START", %{"messageId" => id}), item("REASONING_MESSAGE_START", %{"messageId" => id, "role" => "assistant"})],
         %{st | reasoning: id}}
      end

    {opening ++ [item("REASONING_MESSAGE_CONTENT", %{"messageId" => st.reasoning, "delta" => delta})], st}
  end

  def render(%Event{type: "message_completed"}, st) do
    {a, st} = close_reasoning(st)
    {b, st} = close_message(st)
    {a ++ b, st}
  end

  def render(%Event{type: "toolcall_delta", data: data} = ev, st) do
    {closing, st} = close_message(st)
    {id, name, st, start} = start_call(st, ev, data)
    delta = Map.get(data, "delta")
    args = if is_binary(delta) and delta != "", do: [item("TOOL_CALL_ARGS", %{"toolCallId" => id, "delta" => delta})], else: []
    _ = name
    {closing ++ start ++ args, st}
  end

  def render(%Event{type: "tool_started", data: %{"tool_call_id" => real_id, "name" => name} = data}, st) do
    {closing, st} = close_message(st)
    {call_id, st} = claim_call(st, real_id, name)

    {start_and_args, st} =
      case Map.get(st.calls, call_id) do
        %{started?: true} ->
          {[], st}

        _ ->
          args = Jason.encode!(Map.get(data, "arguments") || %{})

          {[item("TOOL_CALL_START", %{"toolCallId" => call_id, "toolCallName" => name}), item("TOOL_CALL_ARGS", %{"toolCallId" => call_id, "delta" => args})],
           put_call(st, call_id, %{name: name, started?: true})}
      end

    {closing ++ start_and_args ++ [item("TOOL_CALL_END", %{"toolCallId" => call_id})], st}
  end

  def render(%Event{type: "tool_completed", data: %{"tool_call_id" => real_id} = data}, st) do
    {call_id, st} = claim_result(st, real_id)
    {[tool_result(st, call_id, data["output"])], st}
  end

  def render(%Event{type: "tool_blocked", data: %{"tool_call_id" => real_id, "name" => name, "reason" => reason}}, st) do
    # A blocked call never started, so it has no `TOOL_CALL_START` yet.
    {call_id, st} = claim_call(st, real_id, name)
    {start, st} = if Map.get(st.calls, call_id), do: {[], st}, else: {[item("TOOL_CALL_START", %{"toolCallId" => call_id, "toolCallName" => name}), item("TOOL_CALL_END", %{"toolCallId" => call_id})], put_call(st, call_id, %{name: name, started?: true})}
    {start ++ [tool_result(st, call_id, "Blocked: #{reason}"), custom("tool_blocked", %{"toolCallId" => call_id, "reason" => reason})], st}
  end

  def render(%Event{type: "turn_completed", data: data}, st) do
    {a, st} = close_reasoning(st)
    {b, st} = close_message(st)
    {a ++ b ++ [item("RUN_FINISHED", %{"threadId" => st.thread_id, "runId" => st.run_id, "result" => finish_result(data)})], reset_run(st)}
  end

  def render(%Event{type: "turn_error", data: %{"error" => error}}, st), do: finish_error(st, to_string(error), nil)
  def render(%Event{type: "turn_cancelled"}, st), do: finish_error(st, "The run was cancelled.", "cancelled")

  def render(%Event{type: "compaction_completed"}, st) do
    {[item("MESSAGES_SNAPSHOT", %{"messages" => messages(st)})], st}
  end

  def render(%Event{type: "stream_reset"} = ev, st) do
    {a, st} = close_reasoning(st)
    {b, st} = close_message(st)
    {a ++ b ++ [custom("stream_reset", %{"retryInMs" => ev.data["retry_in_ms"]})], st}
  end

  def render(%Event{type: "permission_request"} = ev, st) do
    pending = %{
      "requestId" => ev.data["request_id"],
      "toolCallId" => ev.data["tool_call_id"],
      "toolName" => ev.data["tool_name"],
      "reason" => ev.data["reason"],
      "risk" => ev.data["risk"]
    }

    {delta, st} = project(st, &Map.put(&1, "pendingPermission", pending))
    {[custom("permission_request", Map.drop(Event.to_wire(ev), ["type", "v"]) |> camelize()) | delta], st}
  end

  def render(%Event{type: "ui_request"} = ev, st), do: {[custom("ui_request", Map.drop(Event.to_wire(ev), ["type", "v"]) |> camelize())], st}

  def render(%Event{type: "ui_resolved", data: %{"request_id" => rid} = data}, st) do
    {delta, st} =
      project(st, fn proj ->
        if get_in(proj, ["pendingPermission", "requestId"]) == rid, do: Map.put(proj, "pendingPermission", nil), else: proj
      end)

    {[custom("ui_resolved", %{"requestId" => rid, "outcome" => data["outcome"]}) | delta], st}
  end

  def render(%Event{type: "notice", data: data}, st), do: {[custom("notice", %{"level" => data["level"], "message" => data["message"]})], st}

  def render(%Event{type: type, data: data}, st) when type in ["subagent_started", "subagent_finished"], do: {[custom(type, camelize(data))], st}

  def render(%Event{type: "state_changed", data: %{"status" => status}}, st), do: project(st, &Map.put(&1, "status", status))
  def render(%Event{type: "mode_changed", data: data}, st), do: project(st, &Map.merge(&1, %{"mode" => data["mode"], "maxMode" => data["max_mode"]}))
  def render(%Event{type: "plan_updated", data: %{"entries" => entries}}, st), do: project(st, &Map.put(&1, "plan", entries))

  def render(%Event{type: "usage_updated", data: data}, st) do
    project(st, &Map.put(&1, "usage", %{"inputTokens" => data["total_input_tokens"], "outputTokens" => data["total_output_tokens"]}))
  end

  def render(%Event{}, st), do: {[], st}

  @impl true
  def flush(st) do
    {a, st} = close_reasoning(st)
    {b, st} = close_message(st)
    {a ++ b, st}
  end

  @doc "Merges consecutive content items of the same message or tool call into one."
  @spec coalesce([map()]) :: [map()]
  def coalesce(items) do
    items
    |> Enum.reduce([], fn
      %{"type" => type, "delta" => d} = cur, [%{"type" => type, "delta" => prev} = last | rest]
      when type in ["TEXT_MESSAGE_CONTENT", "REASONING_MESSAGE_CONTENT", "TOOL_CALL_ARGS"] ->
        if same_target?(cur, last), do: [%{last | "delta" => prev <> d} | rest], else: [cur, last | rest]

      cur, acc ->
        [cur | acc]
    end)
    |> Enum.reverse()
  end

  defp same_target?(%{"messageId" => a}, %{"messageId" => b}), do: a == b
  defp same_target?(%{"toolCallId" => a}, %{"toolCallId" => b}), do: a == b
  defp same_target?(_, _), do: false

  # --- Messages ---

  defp open_message(%__MODULE__{message: id} = st, _ev) when is_binary(id), do: {[], st}

  defp open_message(st, ev) do
    {id, st} = next_id(st, ev, "msg")
    {[item("TEXT_MESSAGE_START", %{"messageId" => id, "role" => "assistant"})], %{st | message: id}}
  end

  defp close_message(%__MODULE__{message: nil} = st), do: {[], st}
  defp close_message(st), do: {[item("TEXT_MESSAGE_END", %{"messageId" => st.message})], %{st | message: nil}}

  defp close_reasoning(%__MODULE__{reasoning: nil} = st), do: {[], st}

  defp close_reasoning(st) do
    {[item("REASONING_MESSAGE_END", %{"messageId" => st.reasoning}), item("REASONING_END", %{"messageId" => st.reasoning})], %{st | reasoning: nil}}
  end

  defp next_id(st, ev, prefix), do: {"#{prefix}-#{ev.turn_id || "x"}-#{st.seq + 1}", %{st | seq: st.seq + 1}}

  # --- Tool calls ---
  # A streamed call is announced by its first `toolcall_delta`, before the id the machine
  # uses (`tool_call_id`) is known unless the provider event carried it. `calls` maps the id that
  # was announced to its state. `call_order` holds announced ids that no `tool_started` has claimed.

  defp start_call(st, ev, data) do
    announced = Map.get(data, "id") || "call-#{ev.turn_id || "x"}-#{Map.get(data, "index")}"
    name = Map.get(data, "name") || "unknown"

    if Map.has_key?(st.calls, announced) do
      {announced, name, st, []}
    else
      st = put_call(st, announced, %{name: name, started?: true})
      st = %{st | call_order: st.call_order ++ [announced]}
      {announced, name, st, [item("TOOL_CALL_START", %{"toolCallId" => announced, "toolCallName" => name})]}
    end
  end

  # `tool_started` carries the real id. Use the announced call with that id, else the oldest
  # unclaimed announced call, else the real id itself.
  defp claim_call(st, real_id, _name) do
    cond do
      Map.has_key?(st.calls, real_id) ->
        {real_id, %{st | call_order: List.delete(st.call_order, real_id)} |> alias_call(real_id, real_id)}

      st.call_order != [] ->
        [first | rest] = st.call_order
        {first, %{st | call_order: rest} |> alias_call(real_id, first)}

      true ->
        {real_id, alias_call(st, real_id, real_id)}
    end
  end

  defp claim_result(st, real_id), do: {get_in(st.calls, [{:alias, real_id}]) || real_id, st}

  defp alias_call(st, real_id, call_id), do: %{st | calls: Map.put(st.calls, {:alias, real_id}, call_id)}
  defp put_call(st, id, info), do: %{st | calls: Map.put(st.calls, id, info)}

  defp tool_result(st, call_id, output) do
    content = if is_binary(output), do: output, else: Jason.encode!(output)
    item("TOOL_CALL_RESULT", %{"messageId" => "tool-#{call_id}-#{st.seq}", "toolCallId" => call_id, "content" => content, "role" => "tool"})
  end

  # --- Run end ---

  defp finish_error(st, message, code) do
    {a, st} = close_reasoning(st)
    {b, st} = close_message(st)
    fields = %{"message" => message} |> then(&if(code, do: Map.put(&1, "code", code), else: &1))
    {a ++ b ++ [item("RUN_ERROR", fields)], reset_run(st)}
  end

  defp finish_result(%{"result" => %{} = result}), do: result |> Map.take(["content"]) |> then(&if(&1 == %{}, do: nil, else: &1))
  defp finish_result(_), do: nil

  defp reset_run(st), do: %{st | calls: %{}, call_order: [], run_id: nil}

  # --- State ---

  defp project(st, fun) do
    next = fun.(st.projection)
    st = %{st | projection: next}

    case Jsonpatch.diff(st.sent, next) do
      [] -> {[], st}
      ops -> {[item("STATE_DELTA", %{"delta" => ops})], %{st | sent: next}}
    end
  end

  defp messages(%__MODULE__{messages_fun: fun}) when is_function(fun, 0), do: fun.()
  defp messages(_), do: []

  # --- Items ---

  defp item(type, fields), do: Map.merge(fields, %{"type" => type, "timestamp" => System.system_time(:millisecond)})
  defp custom(name, value), do: item("CUSTOM", %{"name" => name, "value" => value})

  defp camelize(%{} = map) do
    Map.new(map, fn {k, v} -> {camel(k), if(is_map(v), do: camelize(v), else: v)} end)
  end

  defp camel(key) when is_binary(key) do
    case String.split(key, "_") do
      [only] -> only
      [first | rest] -> first <> Enum.map_join(rest, &String.capitalize/1)
    end
  end

  defp camel(key), do: key
end
