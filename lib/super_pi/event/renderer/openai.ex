defmodule SuperPi.Event.Renderer.OpenAI do
  @moduledoc """
  Renders events as OpenAI `chat.completion.chunk` maps for the Gateway's SSE stream.

  - `text_delta` becomes `delta.content`.
  - `thinking_delta` becomes `delta.reasoning_content`.
  - `tool_started` and `tool_completed` become short progress lines in `delta.reasoning_content`, so
    a client shows tool use without the progress entering the answer text.
  - `permission_request` becomes a `reasoning_content` line (a Gateway client cannot answer it, so
    `Permissions` fails closed and the tool call is blocked).

  Every other event produces no chunk. The first chunk (role) and the closing chunks (stop, usage)
  belong to the HTTP handler, which knows the usage totals.

  Options: `:id`, `:created` (Unix seconds), `:model`.
  """
  @behaviour SuperPi.Event.Renderer

  alias SuperPi.Event

  @impl true
  def init(opts) do
    %{
      id: Keyword.fetch!(opts, :id),
      created: Keyword.get_lazy(opts, :created, fn -> System.system_time(:second) end),
      model: Keyword.fetch!(opts, :model)
    }
  end

  @impl true
  def render(%Event{type: "text_delta", data: %{"delta" => delta}}, st), do: {[chunk(st, %{"content" => delta})], st}
  def render(%Event{type: "thinking_delta", data: %{"delta" => delta}}, st), do: {[chunk(st, %{"reasoning_content" => delta})], st}

  def render(%Event{type: "tool_started", data: %{"name" => name} = data}, st) do
    args = Map.get(data, "args") || Map.get(data, "arguments") || %{}
    {[chunk(st, %{"reasoning_content" => "⚙️ Executing #{name}: #{arg_preview(args)}"})], st}
  end

  def render(%Event{type: "tool_completed", data: %{"name" => name} = data}, st) do
    label = if Map.get(data, "is_error", false), do: "❌", else: "✅"
    {[chunk(st, %{"reasoning_content" => "#{label} #{name} completed#{out_preview(Map.get(data, "output", ""))}\n\n"})], st}
  end

  def render(%Event{type: "permission_request", data: %{"tool_name" => name}}, st) do
    {[chunk(st, %{"reasoning_content" => "🔒 #{name} needs approval\n"})], st}
  end

  def render(%Event{}, st), do: {[], st}

  @impl true
  def flush(st), do: {[], st}

  @doc "A chunk with an empty delta and a `finish_reason`, for the handler's closing frame."
  @spec finish_chunk(map(), String.t()) :: map()
  def finish_chunk(st, reason), do: wrap(st, %{"index" => 0, "delta" => %{}, "finish_reason" => reason})

  @doc "The chunk that carries only the assistant role. The handler sends it first."
  @spec role_chunk(map()) :: map()
  def role_chunk(st), do: chunk(st, %{"role" => "assistant"})

  @doc "The usage chunk. It has no choices."
  @spec usage_chunk(map(), map()) :: map()
  def usage_chunk(st, usage), do: st |> wrap(nil) |> Map.merge(%{"choices" => [], "usage" => usage})

  defp chunk(st, delta), do: wrap(st, %{"index" => 0, "delta" => delta, "finish_reason" => nil})

  defp wrap(st, nil), do: %{"id" => st.id, "object" => "chat.completion.chunk", "created" => st.created, "model" => st.model}
  defp wrap(st, choice), do: st |> wrap(nil) |> Map.put("choices", [choice])

  defp arg_preview(%{"command" => cmd}) when is_binary(cmd), do: "$ #{cmd}\n"
  defp arg_preview(%{"path" => p}) when is_binary(p), do: "#{p}\n"
  defp arg_preview(%{"query" => q}) when is_binary(q), do: "query: #{q}\n"

  defp arg_preview(other) do
    case Jason.encode(other) do
      {:ok, json} -> "#{json}\n"
      _ -> "#{inspect(other)}\n"
    end
  end

  defp out_preview(out) do
    raw = out |> out_text() |> String.trim()

    if raw == "", do: "", else: " -> " <> String.slice(raw, 0..80) <> if(String.length(raw) > 80, do: "...", else: "")
  end

  defp out_text(out) when is_binary(out), do: out

  defp out_text(out) do
    case Jason.encode(out) do
      {:ok, json} -> json
      _ -> inspect(out)
    end
  end
end
