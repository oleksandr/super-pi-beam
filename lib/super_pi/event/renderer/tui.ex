defmodule SuperPi.Event.Renderer.TUI do
  @moduledoc """
  Renders events for a terminal. The output is tagged, so the terminal code decides what to print:

  | Item | From | Meaning |
  |---|---|---|
  | `{:text, binary}` | `text_delta` | Answer text, written as it comes. |
  | `{:thinking, binary}` | `thinking_delta` | Reasoning text. |
  | `{:line, binary}` | tool, notice and compaction events | A status line. |
  | `{:ask, wire}` | `ui_request` of kind `questionnaire` | A question for the user. |
  | `{:permission, wire}` | `permission_request` | A tool call that waits for approval. |
  | `{:done, :ok \\| :cancelled \\| {:error, reason}}` | `turn_*` | The turn ended. |

  Stateless: `init/1` returns `nil`.
  """
  @behaviour SuperPi.Event.Renderer

  alias SuperPi.Event

  @impl true
  def init(_opts), do: nil

  @impl true
  def render(%Event{type: "text_delta", data: %{"delta" => d}}, st) when is_binary(d),
    do: {[{:text, d}], st}

  def render(%Event{type: "thinking_delta", data: %{"delta" => d}}, st) when is_binary(d),
    do: {[{:thinking, d}], st}

  def render(%Event{type: "tool_started", data: %{"name" => n}}, st),
    do: {[{:line, "[tool] #{n}"}], st}

  def render(%Event{type: "tool_blocked", data: %{"name" => n, "reason" => r}}, st),
    do: {[{:line, "[blocked] #{n}: #{r}"}], st}

  def render(%Event{type: "tool_completed", data: %{"name" => n} = d}, st),
    do: {[{:line, "[#{if d["is_error"], do: "failed", else: "done"}] #{n}"}], st}

  def render(%Event{type: "notice", data: %{"message" => m}}, st),
    do: {[{:line, "[notice] #{m}"}], st}

  def render(%Event{type: "compaction_completed"}, st), do: {[{:line, "[compacted]"}], st}

  def render(%Event{type: "ui_request", data: %{"kind" => "questionnaire"} = d}, st),
    do: {[{:ask, Map.put(d, "type", "ui_request")}], st}

  def render(%Event{type: "permission_request"} = ev, st),
    do: {[{:permission, Event.to_wire(ev)}], st}

  def render(%Event{type: "turn_completed"}, st), do: {[{:done, :ok}], st}
  def render(%Event{type: "turn_cancelled"}, st), do: {[{:done, :cancelled}], st}
  def render(%Event{type: "turn_error", data: d}, st), do: {[{:done, {:error, d["error"]}}], st}
  def render(%Event{}, st), do: {[], st}

  @impl true
  def flush(st), do: {[], st}
end
