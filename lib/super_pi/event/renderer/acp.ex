defmodule SuperPi.Event.Renderer.ACP do
  @moduledoc """
  Renders events as [Agent Client Protocol](https://agentclientprotocol.com) `session/update`
  payloads, for `SuperPi.ACP.Server`.

  Output items:

  - `{:update, map}` - the `update` of a `session/update` notification.
  - `{:permission, params, request_id}` - params of a `session/request_permission` request. The
    server sends it and answers `SuperPi.UI.Broker.respond(request_id, option_id)`.

  | Event | ACP |
  |---|---|
  | `text_delta` | `agent_message_chunk` |
  | `thinking_delta` | `agent_thought_chunk` |
  | `tool_started` | `tool_call`, status `pending` |
  | `permission_request` | `session/request_permission` for that tool call |
  | `ui_resolved` of a permission | `tool_call_update`, status `in_progress` (on approval) |
  | `tool_completed` | `tool_call_update`, status `completed` or `failed` |
  | `tool_blocked` | `tool_call_update`, status `failed` |
  | `plan_updated` | `plan` |
  | `mode_changed` | `current_mode_update` |
  | `turn_*` | nothing. The server answers `session/prompt` with a stop reason. |

  A tool call is `pending` from `tool_started` until it is approved, or until it completes when no
  approval was needed. The permission option kinds are already ACP's (`allow_once`, `allow_always`,
  `reject_once`, `reject_always`), so the mapping is a rename of fields.

  Running commands are shown as a `tool_call` of kind `execute`, never through the editor's
  `terminal/*` methods. `SandboxRunner` gives process-group kill, output spill and the sandbox, and
  an editor terminal gives none of that and bypasses `permissions.deny`.

  Options: `:session_id`.
  """
  @behaviour SuperPi.Event.Renderer

  alias SuperPi.Event

  @path_keys ["path", "file_path", "to_path"]

  @impl true
  def init(opts), do: %{session_id: Keyword.get(opts, :session_id), calls: %{}, permissions: %{}}

  @impl true
  def render(%Event{type: "text_delta", data: %{"delta" => d}}, st), do: {[{:update, chunk("agent_message_chunk", d)}], st}
  def render(%Event{type: "thinking_delta", data: %{"delta" => d}}, st), do: {[{:update, chunk("agent_thought_chunk", d)}], st}

  def render(%Event{type: "tool_started", data: %{"tool_call_id" => id, "name" => name} = data}, st) do
    args = Map.get(data, "arguments") || %{}

    call = %{
      "sessionUpdate" => "tool_call",
      "toolCallId" => id,
      "title" => title(name, args),
      "kind" => kind(name),
      "status" => "pending",
      "rawInput" => args,
      "locations" => locations(args)
    }

    {[{:update, call}], put_in(st.calls[id], %{name: name, status: "pending"})}
  end

  def render(%Event{type: "permission_request", data: data}, st) do
    id = data["tool_call_id"]
    known = Map.get(st.calls, id, %{})

    params = %{
      "sessionId" => st.session_id,
      "toolCall" => %{
        "toolCallId" => id,
        "title" => title(data["tool_name"], data["arguments"] || %{}),
        "kind" => kind(data["tool_name"]),
        "status" => Map.get(known, :status, "pending"),
        "rawInput" => data["arguments"] || %{}
      },
      "options" => Enum.map(data["options"] || [], &%{"optionId" => &1["option_id"], "name" => &1["name"], "kind" => &1["kind"]}),
      "_meta" => %{"reason" => data["reason"], "risk" => data["risk"]}
    }

    {[{:permission, params, data["request_id"]}], put_in(st.permissions[data["request_id"]], id)}
  end

  # An approved call starts to run. A refusal ends in `tool_completed` (a failed result), so only
  # an approval needs an update here.
  def render(%Event{type: "ui_resolved", data: %{"request_id" => rid, "outcome" => "answered"}}, st) do
    case Map.pop(st.permissions, rid) do
      {nil, _} -> {[], st}
      {id, rest} -> {[], %{st | permissions: rest}} |> in_progress(id)
    end
  end

  def render(%Event{type: "ui_resolved", data: %{"request_id" => rid}}, st), do: {[], %{st | permissions: Map.delete(st.permissions, rid)}}

  def render(%Event{type: "tool_completed", data: %{"tool_call_id" => id} = data}, st) do
    output = data["output"]

    update = %{
      "sessionUpdate" => "tool_call_update",
      "toolCallId" => id,
      "status" => if(data["is_error"], do: "failed", else: "completed"),
      "content" => [%{"type" => "content", "content" => %{"type" => "text", "text" => text(output)}}],
      "rawOutput" => output
    }

    {[{:update, update}], %{st | calls: Map.delete(st.calls, id)}}
  end

  def render(%Event{type: "tool_blocked", data: %{"tool_call_id" => id, "name" => name, "reason" => reason}}, st) do
    {[{:update, %{"sessionUpdate" => "tool_call_update", "toolCallId" => id, "status" => "failed", "title" => "#{name} (blocked)", "content" => [%{"type" => "content", "content" => %{"type" => "text", "text" => reason}}]}}],
     %{st | calls: Map.delete(st.calls, id)}}
  end

  def render(%Event{type: "plan_updated", data: %{"entries" => entries}}, st) do
    plan = Enum.map(entries, &%{"content" => &1["text"], "priority" => "medium", "status" => if(&1["completed"], do: "completed", else: "pending")})
    {[{:update, %{"sessionUpdate" => "plan", "entries" => plan}}], st}
  end

  def render(%Event{type: "mode_changed", data: %{"mode" => mode}}, st), do: {[{:update, %{"sessionUpdate" => "current_mode_update", "currentModeId" => mode}}], st}
  def render(%Event{}, st), do: {[], st}

  @impl true
  def flush(st), do: {[], st}

  @doc "ACP `kind` of a tool: `read`, `edit`, `search`, `execute`, `fetch` or `other`."
  @spec kind(String.t()) :: String.t()
  def kind(name) when name in ["read", "read_file", "ls", "list_dir", "list_directory"], do: "read"
  def kind(name) when name in ["write", "write_file", "edit", "edit_file"], do: "edit"
  def kind(name) when name in ["grep", "find", "find_files", "search_files", "tool_search", "web_search", "memory_search"], do: "search"
  def kind(name) when name in ["bash", "sh", "terminal", "run_command", "exec"], do: "execute"
  def kind(name) when name in ["web_fetch"], do: "fetch"
  def kind(_), do: "other"

  defp in_progress({[], st}, id) do
    case Map.get(st.calls, id) do
      nil -> {[], st}
      call -> {[{:update, %{"sessionUpdate" => "tool_call_update", "toolCallId" => id, "status" => "in_progress"}}], put_in(st.calls[id], %{call | status: "in_progress"})}
    end
  end

  defp chunk(kind, text), do: %{"sessionUpdate" => kind, "content" => %{"type" => "text", "text" => text}}

  defp title(name, %{"command" => cmd}) when is_binary(cmd), do: "#{name}: #{String.slice(cmd, 0, 80)}"
  defp title(name, %{"url" => url}) when is_binary(url), do: "#{name}: #{String.slice(url, 0, 80)}"
  defp title(name, %{"query" => q}) when is_binary(q), do: "#{name}: #{String.slice(q, 0, 80)}"

  defp title(name, args) do
    case Enum.find_value(@path_keys, &args[&1]) do
      path when is_binary(path) -> "#{name}: #{path}"
      _ -> to_string(name)
    end
  end

  defp locations(args) do
    case Enum.find_value(@path_keys, &args[&1]) do
      path when is_binary(path) and path != "" -> [%{"path" => path}]
      _ -> []
    end
  end

  defp text(out) when is_binary(out), do: out

  defp text(out) do
    case Jason.encode(out) do
      {:ok, json} -> json
      _ -> inspect(out)
    end
  end
end
