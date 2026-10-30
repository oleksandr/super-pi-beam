defmodule SuperPi.AI.Provider do
  @moduledoc """
  Behaviour for a model provider.

  A provider owns one model API. `SuperPi.AI.Providers` selects the provider for a model name.
  To serve a model that Super-Pi does not support, write a module that implements this
  behaviour and register it in the application environment:

      config :super_pi, :providers, [MyApp.MyProvider, SuperPi.AI.Providers.Gemini]

  Providers earlier in the list win. `generate/2` receives the request payload (`:model`,
  `:messages`, `:tools`, and so on) and an `:on_delta` callback. It returns `{:ok, message}`
  or `{:error, reason}`. The message has the shape `%{"role" => "assistant", "content" => [...],
  "usage" => %{...}}`. Call `on_delta` with the events that `SuperPi.AI.StreamNormalizer` emits.
  """

  @typedoc "Streaming callback. Receives `StreamNormalizer` events."
  @type on_delta :: (term() -> any())

  @doc "Stable provider identifier, for example `\"gemini\"`."
  @callback id() :: String.t()

  @doc "Returns true when this provider serves `model`."
  @callback handles?(model :: String.t()) :: boolean()

  @doc "Returns true when the provider has the credentials and settings that it needs."
  @callback configured?() :: boolean()

  @doc "Models to list in catalogs. Each entry has `\"id\"` and `\"label\"`."
  @callback models() :: [%{required(String.t()) => String.t()}]

  @doc "Maps a requested name (for example a harness alias) to the model sent to the API."
  @callback normalize_model(model :: String.t()) :: String.t()

  @doc "Runs a generation request."
  @callback generate(payload :: map(), opts :: [on_delta: on_delta()]) ::
              {:ok, map()} | {:error, term()}

  @optional_callbacks normalize_model: 1

  @doc """
  Readable text for a `generate/2` error reason. Strings pass through unchanged, so text
  formatted once is not escaped again.
  """
  @spec format_error(term()) :: String.t()
  def format_error(reason) when is_binary(reason), do: reason
  def format_error({:http_error, status, message}), do: "HTTP #{status}: #{format_error(message)}"
  def format_error({:request_failed, message}), do: "Request failed: #{format_error(message)}"

  def format_error({:stream_error, %{reason: reason}}),
    do: "Stream error: #{format_error(reason)}"

  def format_error({:gemini_http_error, status, body, raw}),
    do: "HTTP #{status}: #{body_message(body) || body_message(raw) || inspect(body)}"

  def format_error(reason) when is_exception(reason), do: Exception.message(reason)
  # A stream error event, as `SuperPi.AI.StreamNormalizer` emits it.
  def format_error(%{reason: reason}), do: format_error(reason)
  def format_error(reason), do: inspect(reason)

  defp body_message(%{"error" => %{"message" => message}}) when is_binary(message), do: message
  defp body_message(%{"error" => message}) when is_binary(message), do: message
  defp body_message([first | _]), do: body_message(first)

  defp body_message(raw) when is_binary(raw) and raw != "" do
    case Jason.decode(raw) do
      {:ok, decoded} -> body_message(decoded)
      _ -> String.slice(raw, 0, 500)
    end
  end

  defp body_message(_), do: nil
end
