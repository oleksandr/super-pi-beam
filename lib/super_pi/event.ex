defmodule SuperPi.Event do
  @moduledoc """
  The typed turn event: one schema that every interface renders.

  A conversation publishes events on the PubSub topic `"conversation:<id>"` as
  `{:conversation_event, conversation_id, wire_map}`. Before this module each producer built an
  untyped map and each consumer (Gateway, RPC server, TUI) read it again in its own way. Now a
  producer builds an event with one function per type (the only sanctioned construction site, each
  with a `@spec`), and a consumer reads it through a renderer (`SuperPi.Event.Renderer`).

  There is one struct, not one per type. The wire form is a plain map anyway, and a renderer
  matches on `:type`.

  ## Wire form

  `to_wire/1` gives the flat map that consumers have always read, plus `"v"` (schema version, `1`)
  and `"turn_id"` (the id of the turn task, or `nil` outside a turn). Payload keys stay at the top
  level, not under `"data"`, so a consumer that matches `%{"type" => "text_delta", "delta" => d}`
  keeps working. Both additions are purely additive.

  ## Types

  | Type | Payload keys |
  |---|---|
  | `turn_started` | `seq` |
  | `turn_completed` | `stop_reason`, `result`, `seq` |
  | `turn_error` | `error`, `seq` |
  | `turn_cancelled` | `seq` |
  | `text_delta` | `index`, `delta` |
  | `thinking_delta` | `index`, `delta` |
  | `toolcall_delta` | `index`, `delta`, `partial_args`, and `id` and `name` when the provider gave them |
  | `message_completed` | `role`, `content`, `usage` |
  | `tool_started` | `tool_call_id`, `name`, `arguments`, `overwritten_keys` |
  | `tool_blocked` | `tool_call_id`, `name`, `reason` |
  | `tool_completed` | `tool_call_id`, `name`, `is_error`, `output` |
  | `permission_request` | `request_id`, `tool_call_id`, `tool_name`, `arguments`, `reason`, `risk`, `options` |
  | `ui_request` | `request_id` and the request map (for example `kind`, `questions`) |
  | `ui_resolved` | `request_id`, `outcome` |
  | `state_changed` | `status` |
  | `mode_changed` | `mode`, `max_mode` |
  | `stream_reset` | `retry_in_ms` |
  | `compaction_completed` | `head_entry_id`, `summary` |
  | `usage_updated` | `input_tokens`, `output_tokens`, `total_input_tokens`, `total_output_tokens` |
  | `plan_updated` | `entries` (todo items with `id`, `text`, `completed`) |
  | `notice` | `level`, `message` |
  | `watch_started` | `seq` |
  | `subagent_started` | `child_conversation_id`, `role`, `task` |
  | `subagent_finished` | `child_conversation_id`, `status`, `summary` |

  `stop_reason` of `turn_completed` is `"end_turn"`. `permission_request` options carry ACP
  `PermissionOptionKind` values in `kind`: `allow_once`, `allow_always`, `reject_once`, `reject_always`.
  """

  defstruct [:type, :conversation_id, :turn_id, :timestamp_ms, data: %{}, v: 1]

  @type t :: %__MODULE__{
          type: String.t(),
          conversation_id: integer() | nil,
          turn_id: integer() | nil,
          timestamp_ms: integer(),
          data: map(),
          v: pos_integer()
        }

  @types ~w(turn_started turn_completed turn_error turn_cancelled text_delta thinking_delta toolcall_delta
            message_completed tool_started tool_blocked tool_completed permission_request ui_request ui_resolved
            state_changed mode_changed stream_reset compaction_completed usage_updated plan_updated notice watch_started
            subagent_started subagent_finished)

  @envelope ["type", "conversation_id", "turn_id", "timestamp_ms", "v"]

  @doc "The event types."
  @spec types() :: [String.t()]
  def types, do: @types

  @doc "The wire map of an event: its payload at the top level, plus the envelope keys."
  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{} = ev) do
    Map.merge(ev.data, %{
      "type" => ev.type,
      "conversation_id" => ev.conversation_id,
      "turn_id" => ev.turn_id,
      "timestamp_ms" => ev.timestamp_ms,
      "v" => ev.v
    })
  end

  @doc """
  Reads a wire map back into an event. A map from an older producer (no `"v"`, no `"turn_id"`)
  reads as version 1 with no turn.
  """
  @spec from_wire(map()) :: t()
  def from_wire(%{} = wire) do
    %__MODULE__{
      type: Map.get(wire, "type"),
      conversation_id: Map.get(wire, "conversation_id"),
      turn_id: Map.get(wire, "turn_id"),
      timestamp_ms: Map.get(wire, "timestamp_ms") || System.system_time(:millisecond),
      data: Map.drop(wire, @envelope),
      v: Map.get(wire, "v") || 1
    }
  end

  @doc "Publishes an event on the conversation topic."
  @spec publish(t()) :: :ok
  def publish(%__MODULE__{conversation_id: conv_id} = ev) do
    Phoenix.PubSub.broadcast(SuperPi.PubSub, topic(conv_id), {:conversation_event, conv_id, to_wire(ev)})
  end

  @doc "PubSub topic of a conversation."
  @spec topic(integer()) :: String.t()
  def topic(conversation_id), do: "conversation:#{conversation_id}"

  @doc """
  Wraps a map that an extension passed to `ctx.emit_event` into an event. The map must have a
  `"type"`. Keys that belong to the envelope are taken from the arguments, not the map.
  """
  @spec from_extension(integer(), integer() | nil, map()) :: t()
  def from_extension(conversation_id, turn_id, %{} = map) do
    new(Map.get(map, "type", "notice"), conversation_id, turn_id, Map.drop(map, @envelope))
  end

  # --- Builders ---

  @spec turn_started(integer(), integer() | nil, integer()) :: t()
  def turn_started(conv, turn, seq), do: new("turn_started", conv, turn, %{"seq" => seq})

  @spec turn_completed(integer(), integer() | nil, map() | nil, integer()) :: t()
  def turn_completed(conv, turn, result, seq, stop_reason \\ "end_turn"),
    do: new("turn_completed", conv, turn, %{"stop_reason" => stop_reason, "result" => result, "seq" => seq})

  @spec turn_error(integer(), integer() | nil, term(), integer()) :: t()
  def turn_error(conv, turn, error, seq), do: new("turn_error", conv, turn, %{"error" => format_error(error), "seq" => seq})

  @spec turn_cancelled(integer(), integer() | nil, integer()) :: t()
  def turn_cancelled(conv, turn, seq), do: new("turn_cancelled", conv, turn, %{"seq" => seq})

  @spec text_delta(integer(), integer() | nil, integer(), String.t()) :: t()
  def text_delta(conv, turn, index, delta), do: new("text_delta", conv, turn, %{"index" => index, "delta" => delta})

  @spec thinking_delta(integer(), integer() | nil, integer(), String.t()) :: t()
  def thinking_delta(conv, turn, index, delta), do: new("thinking_delta", conv, turn, %{"index" => index, "delta" => delta})

  @spec toolcall_delta(integer(), integer() | nil, integer(), String.t() | nil, term(), keyword()) :: t()
  def toolcall_delta(conv, turn, index, delta, partial_args, call \\ []) do
    data =
      %{"index" => index, "delta" => delta, "partial_args" => partial_args}
      |> then(&if(call[:id], do: Map.put(&1, "id", call[:id]), else: &1))
      |> then(&if(call[:name], do: Map.put(&1, "name", call[:name]), else: &1))

    new("toolcall_delta", conv, turn, data)
  end

  @spec message_completed(integer(), integer() | nil, String.t(), [map()], map()) :: t()
  def message_completed(conv, turn, role, content, usage),
    do: new("message_completed", conv, turn, %{"role" => role, "content" => content, "usage" => usage})

  @spec tool_started(integer(), integer() | nil, String.t(), String.t(), map(), [String.t()]) :: t()
  def tool_started(conv, turn, tool_call_id, name, arguments, overwritten_keys \\ []),
    do: new("tool_started", conv, turn, %{"tool_call_id" => tool_call_id, "name" => name, "arguments" => arguments, "overwritten_keys" => overwritten_keys})

  @spec tool_blocked(integer(), integer() | nil, String.t(), String.t(), String.t()) :: t()
  def tool_blocked(conv, turn, tool_call_id, name, reason),
    do: new("tool_blocked", conv, turn, %{"tool_call_id" => tool_call_id, "name" => name, "reason" => reason})

  @spec tool_completed(integer(), integer() | nil, String.t(), String.t(), boolean(), term()) :: t()
  def tool_completed(conv, turn, tool_call_id, name, is_error, output),
    do: new("tool_completed", conv, turn, %{"tool_call_id" => tool_call_id, "name" => name, "is_error" => is_error, "output" => output})

  @doc """
  A tool call waits for a human decision. `request_id` answers through `SuperPi.UI.Broker.respond/2`
  with the `option_id` of one of `options`.
  """
  @spec permission_request(integer(), integer() | nil, map()) :: t()
  def permission_request(conv, turn, %{} = fields) do
    new("permission_request", conv, turn, Map.take(fields, ~w(request_id tool_call_id tool_name arguments reason risk options)))
  end

  @doc "The four permission options, with ACP `PermissionOptionKind` in `kind`."
  @spec permission_options() :: [map()]
  def permission_options do
    [
      %{"option_id" => "allow_once", "name" => "Allow once", "kind" => "allow_once"},
      %{"option_id" => "allow_always", "name" => "Always allow", "kind" => "allow_always"},
      %{"option_id" => "reject_once", "name" => "Reject", "kind" => "reject_once"},
      %{"option_id" => "reject_always", "name" => "Always reject", "kind" => "reject_always"}
    ]
  end

  @spec ui_request(integer(), String.t(), map()) :: t()
  def ui_request(conv, request_id, %{} = request),
    do: new("ui_request", conv, nil, Map.put(Map.drop(request, @envelope), "request_id", request_id))

  @spec ui_resolved(integer(), String.t(), term()) :: t()
  def ui_resolved(conv, request_id, outcome), do: new("ui_resolved", conv, nil, %{"request_id" => request_id, "outcome" => outcome})

  @spec state_changed(integer(), integer() | nil, String.t()) :: t()
  def state_changed(conv, turn, status), do: new("state_changed", conv, turn, %{"status" => status})

  @spec mode_changed(integer(), String.t(), String.t() | nil) :: t()
  def mode_changed(conv, mode, max_mode), do: new("mode_changed", conv, nil, %{"mode" => mode, "max_mode" => max_mode})

  @spec stream_reset(integer(), integer() | nil, integer()) :: t()
  def stream_reset(conv, turn, retry_in_ms), do: new("stream_reset", conv, turn, %{"retry_in_ms" => retry_in_ms})

  @spec compaction_completed(integer(), term(), String.t() | nil) :: t()
  def compaction_completed(conv, head_entry_id, summary),
    do: new("compaction_completed", conv, nil, %{"head_entry_id" => head_entry_id, "summary" => summary})

  @spec usage_updated(integer(), integer() | nil, map()) :: t()
  def usage_updated(conv, turn, %{} = totals), do: new("usage_updated", conv, turn, Map.take(totals, ~w(input_tokens output_tokens total_input_tokens total_output_tokens)))

  @spec plan_updated(integer(), [map()]) :: t()
  def plan_updated(conv, entries) when is_list(entries), do: new("plan_updated", conv, nil, %{"entries" => entries})

  @spec notice(integer(), integer() | nil, String.t(), String.t()) :: t()
  def notice(conv, turn, level, message) when level in ["info", "warning", "error"],
    do: new("notice", conv, turn, %{"level" => level, "message" => message})

  @spec watch_started(integer(), integer()) :: t()
  def watch_started(conv, seq), do: new("watch_started", conv, nil, %{"seq" => seq})

  # Published on the parent conversation. `turn` is the parent's turn task, `task` the prompt given
  # to the child, `status` one of "completed", "failed", "aborted".
  @spec subagent_started(integer(), integer() | nil, integer(), String.t(), String.t()) :: t()
  def subagent_started(conv, turn, child_conversation_id, role, task),
    do: new("subagent_started", conv, turn, %{"child_conversation_id" => child_conversation_id, "role" => role, "task" => task})

  @spec subagent_finished(integer(), integer() | nil, integer(), String.t(), String.t() | nil) :: t()
  def subagent_finished(conv, turn, child_conversation_id, status, summary),
    do: new("subagent_finished", conv, turn, %{"child_conversation_id" => child_conversation_id, "status" => status, "summary" => summary})

  defp new(type, conv, turn, data) when type in @types or is_binary(type) do
    %__MODULE__{type: type, conversation_id: conv, turn_id: turn, timestamp_ms: System.system_time(:millisecond), data: data}
  end

  defp format_error(error) when is_binary(error), do: error
  defp format_error(error), do: inspect(error)
end
