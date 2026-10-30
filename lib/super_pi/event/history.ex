defmodule SuperPi.Event.History do
  @moduledoc """
  The visible messages of a conversation in a neutral shape, for protocols that must replay history:
  the AG-UI `MESSAGES_SNAPSHOT` (a reconnect, or a compaction) and the ACP `session/load`.

  Each message is a map with `"id"`, `"role"` (`"user"`, `"assistant"` or `"tool"`) and
  `"text"` (the joined text blocks). An assistant message may have `"tool_calls"` (a list of
  `%{"id", "name", "arguments"}`), a tool message has `"tool_call_id"`, `"name"` and `"is_error"`.
  Entries that are not messages (compactions, system state) are left out. A compaction summary
  appears as an assistant message, because the entries that it replaces are no longer visible.
  """

  alias SuperPi.Durable.Context

  @spec messages(integer()) :: [map()]
  def messages(conversation_id) do
    {visible, _graph} = Context.visible_entries_with_graph(conversation_id)

    Enum.flat_map(visible, fn entry ->
      case {entry.kind, entry.data} do
        {"pi.message", %{"role" => role} = data} ->
          [message(entry.id, role, data)]

        {"pi.compaction", %{"summary" => summary}} when is_binary(summary) ->
          [%{"id" => "entry-#{entry.id}", "role" => "assistant", "text" => summary}]

        _ ->
          []
      end
    end)
  end

  @doc "The AG-UI form of `messages/1`."
  @spec agui_messages(integer()) :: [map()]
  def agui_messages(conversation_id) do
    conversation_id
    |> messages()
    |> Enum.map(fn
      %{"role" => "tool"} = m ->
        %{
          "id" => m["id"],
          "role" => "tool",
          "content" => m["text"],
          "toolCallId" => m["tool_call_id"]
        }

      %{"role" => "assistant", "tool_calls" => [_ | _] = calls} = m ->
        %{
          "id" => m["id"],
          "role" => "assistant",
          "content" => m["text"],
          "toolCalls" =>
            Enum.map(
              calls,
              &%{
                "id" => &1["id"],
                "type" => "function",
                "function" => %{
                  "name" => &1["name"],
                  "arguments" => Jason.encode!(&1["arguments"] || %{})
                }
              }
            )
        }

      m ->
        %{"id" => m["id"], "role" => m["role"], "content" => m["text"]}
    end)
  end

  defp message(id, "tool", data) do
    %{
      "id" => "entry-#{id}",
      "role" => "tool",
      "text" => text(data["content"]),
      "tool_call_id" => data["tool_call_id"],
      "name" => data["name"],
      "is_error" => data["is_error"] == true
    }
  end

  defp message(id, role, data) do
    blocks = if is_list(data["content"]), do: data["content"], else: []

    calls =
      for %{"type" => "tool_call"} = b <- blocks,
          do: %{"id" => b["id"], "name" => b["name"], "arguments" => b["arguments"]}

    base = %{"id" => "entry-#{id}", "role" => role, "text" => text(data["content"])}
    if calls == [], do: base, else: Map.put(base, "tool_calls", calls)
  end

  defp text(content) when is_binary(content), do: content

  defp text(blocks) when is_list(blocks) do
    blocks
    |> Enum.map(fn
      %{"type" => "text", "text" => t} when is_binary(t) -> t
      %{"text" => t} when is_binary(t) -> t
      t when is_binary(t) -> t
      _ -> ""
    end)
    |> Enum.join("")
  end

  defp text(_), do: ""
end
