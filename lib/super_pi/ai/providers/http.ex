defmodule SuperPi.AI.Providers.HTTP do
  @moduledoc """
  Streams one request to an SSE model API and normalizes the events (`SuperPi.AI.StreamNormalizer`).
  Shared by the Anthropic and OpenAI providers.

  Returns what `SuperPi.AI.Provider.generate/2` returns, plus `{:retry_after, ms}` for a rate limit
  or an overloaded server, which the conversation machine turns into a backoff.

  Req's own retry is off. The machine owns retries (backoff, cap, durable state), and a second
  layer of retries would repeat a request the first one already counted.
  """

  require Logger

  alias SuperPi.AI.StreamNormalizer

  @default_timeout 120_000
  @stream_retry_ms 2_000

  @spec stream(atom(), String.t(), String.t(), list(), map(), keyword()) ::
          {:ok, map()} | {:retry_after, non_neg_integer()} | {:error, term()}
  def stream(provider, model, url, headers, body, opts \\ []) do
    on_delta = Keyword.get(opts, :on_delta, fn _ -> :ok end)
    init = StreamNormalizer.new(provider, model)

    req_opts =
      [
        headers: headers,
        json: body,
        retry: false,
        receive_timeout: @default_timeout,
        into: fn {:data, chunk}, {req, resp} ->
          {:cont, {req, feed(resp, chunk, init, on_delta)}}
        end
      ] ++ Application.get_env(:super_pi, :ai_req_options, [])

    case Req.post(url, req_opts) do
      {:ok, %Req.Response{status: 200} = resp} ->
        finish(provider, model, resp, init, on_delta)

      {:ok, %Req.Response{status: status} = resp} when status in [429, 529] ->
        {:retry_after, retry_after_ms(resp)}

      {:ok, %Req.Response{status: status} = resp} ->
        {:error, {:http_error, status, error_message(resp)}}

      {:error, exception} ->
        {:error, {:request_failed, Exception.message(exception)}}
    end
  end

  # A non-200 body is kept raw (it is JSON, not SSE); a 200 body goes through the normalizer.
  defp feed(%Req.Response{status: 200} = resp, chunk, init, on_delta) do
    st = Req.Response.get_private(resp, :normalizer, init)
    {events, next} = StreamNormalizer.feed_chunk(st, chunk)
    Enum.each(events, on_delta)

    # Newest first; `finish/5` reverses once.
    resp
    |> Req.Response.put_private(:normalizer, next)
    |> Req.Response.put_private(
      :events_rev,
      Enum.reverse(events, Req.Response.get_private(resp, :events_rev, []))
    )
  end

  defp feed(resp, chunk, _init, _on_delta) do
    Req.Response.put_private(resp, :raw, Req.Response.get_private(resp, :raw, "") <> chunk)
  end

  defp finish(provider, model, resp, init, on_delta) do
    st = Req.Response.get_private(resp, :normalizer, init)
    {flushed, final} = StreamNormalizer.flush(st)
    Enum.each(flushed, on_delta)
    events = Enum.reverse(Req.Response.get_private(resp, :events_rev, []), flushed)

    error =
      Enum.find_value(events, fn
        {:error, err} -> err
        _ -> nil
      end)

    done =
      Enum.find_value(Enum.reverse(events), fn
        {:done, d} -> d
        _ -> nil
      end)

    case {error, done} do
      {%{retryable: true} = err, _} ->
        Logger.warning("[#{provider}] retryable error in the stream: #{inspect(err.reason)}")
        {:retry_after, @stream_retry_ms}

      {nil, %{content: content}} ->
        {:ok,
         %{
           "role" => "assistant",
           "provider" => Atom.to_string(provider),
           "model" => model,
           "content" => content,
           "usage" => final.usage,
           "stop_reason" => final.stop_reason
         }}

      # The connection closed before the terminal event. The blocks may be cut anywhere, a tool
      # call's arguments too, so nothing of this attempt is used.
      {nil, nil} ->
        Logger.warning("[#{provider}] stream ended without its terminal event; retrying")
        {:retry_after, @stream_retry_ms}

      {err, _} ->
        {:error, {:stream_error, err}}
    end
  end

  # `retry-after` is a number of seconds. Capped, so a wrong header cannot stall a turn for an hour.
  defp retry_after_ms(resp) do
    case Req.Response.get_header(resp, "retry-after") do
      [value | _] ->
        case Integer.parse(String.trim(value)) do
          {seconds, _} when seconds >= 0 -> min(seconds * 1_000, 60_000)
          _ -> 2_000
        end

      _ ->
        2_000
    end
  end

  # The provider's own message when the body is JSON with one (both APIs put it under error.message).
  defp error_message(resp) do
    raw = Req.Response.get_private(resp, :raw, "")

    case Jason.decode(raw) do
      {:ok, %{"error" => %{"message" => message}}} when is_binary(message) -> message
      {:ok, %{"error" => message}} when is_binary(message) -> message
      _ -> String.slice(raw, 0, 500)
    end
  end
end
