defmodule SuperPi.AI.Providers do
  @moduledoc """
  Provider registry. Selects the `SuperPi.AI.Provider` that serves a model.

  Resolution order:

  1. In mock mode (`config :super_pi, mock_llm: true`) only `SuperPi.AI.Providers.Mock` is active.
     Mock mode is for tests and demos. It never turns on by itself.
  2. Otherwise the first provider in `config :super_pi, :providers` whose `handles?/1` returns
     true serves the model. The default list is Gemini, Anthropic and OpenAI. A provider with no key is listed in the catalog as not available.
  3. If that provider is not configured, or no provider handles the model, the result is an
     error. There is no silent fallback.
  """

  @default_providers [SuperPi.AI.Providers.Gemini, SuperPi.AI.Providers.Anthropic, SuperPi.AI.Providers.OpenAI]

  @type error ::
          {:no_provider, String.t()}
          | {:not_configured, provider_id :: String.t()}

  @doc "Providers registered in the application environment."
  @spec registered() :: [module()]
  def registered, do: Application.get_env(:super_pi, :providers, @default_providers)

  @doc "Providers that can serve requests now."
  @spec active() :: [module()]
  def active do
    if mock?(), do: [SuperPi.AI.Providers.Mock], else: registered()
  end

  @doc "Returns the provider for `model` and the model name to send to it."
  @spec resolve(String.t()) :: {:ok, module(), String.t()} | {:error, error()}
  def resolve(model) when is_binary(model) do
    case Enum.find(active(), & &1.handles?(model)) do
      nil ->
        {:error, {:no_provider, model}}

      provider ->
        if provider.configured?() do
          {:ok, provider, normalize(provider, model)}
        else
          {:error, {:not_configured, provider.id()}}
        end
    end
  end

  @doc "Model catalog of all registered providers, with the provider id and availability."
  @spec catalog() :: [map()]
  def catalog do
    Enum.flat_map(registered(), fn provider ->
      available = provider.configured?()

      Enum.map(provider.models(), fn m ->
        Map.merge(m, %{"provider" => provider.id(), "available" => available})
      end)
    end)
  end

  @doc "Human-readable message for a resolution error."
  @spec format_error(error()) :: String.t()
  def format_error({:no_provider, model}),
    do: "No provider is registered for model #{model}. Register one in config :super_pi, :providers."

  def format_error({:not_configured, id}),
    do: "Provider #{id} is not configured (missing API key or settings)."

  defp normalize(provider, model) do
    if function_exported?(provider, :normalize_model, 1),
      do: provider.normalize_model(model),
      else: model
  end

  defp mock?, do: Application.get_env(:super_pi, :mock_llm, false) == true
end
