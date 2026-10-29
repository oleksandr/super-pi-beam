defmodule SuperPi.Harness do
  @moduledoc """
  Pluggable Agent Harness Specification and Registry (`REQ-HARNESS-01`).

  Enables running Super-Pi-BEAM under distinct agent personalities and customization packs
  (Default Super-Pi, Antigravity AGY, Architecture Planner, and future custom extensions)
  uniformly across OpenCode, the OpenAI HTTP Gateway, and MCP without polluting the core engine.
  """

  @doc "Unique string identifier for the harness (e.g., 'super-pi-agent', 'super-pi-agy')"
  @callback id() :: String.t()

  @doc "Human-readable name"
  @callback name() :: String.t()

  @doc "Short description for model listings and discovery"
  @callback description() :: String.t()

  @doc "List of SuperPi.Extension modules active in this harness"
  @callback extensions(opts :: keyword()) :: list(module())

  @doc "Default document configuration for the conversation agent"
  @callback agent_defaults(opts :: keyword()) :: map()

  @registry %{
    "default" => SuperPi.Harness.Default,
    "super-pi" => SuperPi.Harness.Default,
    "super-pi-agent" => SuperPi.Harness.Default,
    "super-pi-fast" => SuperPi.Harness.Default,
    "agy" => SuperPi.Harness.AGY,
    "antigravity" => SuperPi.Harness.AGY,
    "super-pi-agy" => SuperPi.Harness.AGY,
    "planner" => SuperPi.Harness.Planner,
    "super-pi-planner" => SuperPi.Harness.Planner,
    "auto" => SuperPi.Harness.Autonomous,
    "super-pi-auto" => SuperPi.Harness.Autonomous,
    "interactive" => SuperPi.Harness.Interactive,
    "super-pi-interactive" => SuperPi.Harness.Interactive
  }

  @doc """
  Lists all available harness modules.
  """
  def list do
    [
      SuperPi.Harness.Default,
      SuperPi.Harness.Autonomous,
      SuperPi.Harness.Interactive,
      SuperPi.Harness.AGY,
      SuperPi.Harness.Planner
    ]
  end

  @doc """
  Returns true if the given model name or ID corresponds to a registered harness.
  """
  def harness?(name_or_id) when is_binary(name_or_id) do
    key =
      name_or_id
      |> String.downcase()
      |> String.replace_prefix("super-pi/", "")

    Map.has_key?(@registry, key)
  end

  def harness?(_), do: false

  @doc """
  Resolves a model name, alias, or harness ID to its corresponding Harness module.
  Falls back to `SuperPi.Harness.Default` if unknown.
  """
  def resolve(name_or_id) when is_binary(name_or_id) do
    key =
      name_or_id
      |> String.downcase()
      |> String.replace_prefix("super-pi/", "")

    Map.get(@registry, key, SuperPi.Harness.Default)
  end

  def resolve(_), do: SuperPi.Harness.Default
end
