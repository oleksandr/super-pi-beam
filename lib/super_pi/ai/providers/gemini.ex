defmodule SuperPi.AI.Providers.Gemini do
  @moduledoc """
  Google Gemini provider. Wraps `SuperPi.AI.GeminiClient`.

  Serves `gemini-*` and `google/*` models. When a key is configured, it also maps harness
  names (`super-pi-code`, `super-pi-planner`, `default`, and so on) to a Gemini model.
  """

  @behaviour SuperPi.AI.Provider

  alias SuperPi.AI.GeminiClient

  @models [
    {"gemini-3-flash-preview", "Gemini 3 Flash Preview (Live)"},
    {"gemini-4-argon-medium", "Gemini 4 Argon (Medium)"},
    {"gemini-4-argon-high", "Gemini 4 Argon (High)"},
    {"gemini-4-argon-low", "Gemini 4 Argon (Low)"},
    {"gemini-3.8-flash-high", "Gemini 3.8 Flash (High)"},
    {"gemini-3.8-flash-medium", "Gemini 3.8 Flash (Medium)"},
    {"gemini-3.8-flash-low", "Gemini 3.8 Flash (Low)"}
  ]

  @impl true
  def id, do: "gemini"

  @impl true
  def handles?(model) do
    String.starts_with?(model, "gemini-") or String.starts_with?(model, "google/") or alias?(model)
  end

  @impl true
  def configured?, do: GeminiClient.configured?()

  @impl true
  def models, do: Enum.map(@models, fn {id, label} -> %{"id" => id, "label" => label} end)

  @impl true
  def normalize_model("google/" <> rest), do: rest
  def normalize_model("gemini-" <> _ = model), do: model
  def normalize_model(m) when m in ["super-pi-planner", "planner"], do: "gemini-3.1-pro-preview"
  def normalize_model(_alias), do: "gemini-3-flash-preview"

  @impl true
  def generate(payload, opts), do: GeminiClient.generate(payload, opts)

  defp alias?(model) do
    model == "default" or SuperPi.Harness.harness?(model)
  end
end
