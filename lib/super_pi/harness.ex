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

  @builtin_harnesses [
    SuperPi.Harness.Default,
    SuperPi.Harness.Autonomous,
    SuperPi.Harness.Interactive,
    SuperPi.Harness.AGY,
    SuperPi.Harness.Planner
  ]

  @doc """
  Lists all available harness modules, including any configured via application env.
  """
  def list do
    extra = Application.get_env(:super_pi, :extra_harnesses, [])
    Enum.uniq(@builtin_harnesses ++ extra)
  end

  @doc """
  Returns true if the given model name or ID corresponds to a registered harness.
  """
  def harness?(module) when is_atom(module) do
    (Code.ensure_loaded?(module) and function_exported?(module, :id, 0)) or
      Map.has_key?(@registry, to_string(module))
  end

  def harness?(name_or_id) when is_binary(name_or_id) do
    key =
      name_or_id
      |> String.downcase()
      |> String.replace_prefix("super-pi/", "")

    Map.has_key?(@registry, key)
  end

  def harness?(_), do: false

  @doc """
  Resolves a model name, alias, module, or harness ID to its corresponding Harness module.
  Falls back to `SuperPi.Harness.Default` if unknown.
  """
  def resolve(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :id, 0) do
      module
    else
      Map.get(@registry, to_string(module), SuperPi.Harness.Default)
    end
  end

  def resolve(name_or_id) when is_binary(name_or_id) do
    key =
      name_or_id
      |> String.downcase()
      |> String.replace_prefix("super-pi/", "")

    case Map.get(@registry, key) do
      nil ->
        try do
          mod = String.to_existing_atom(name_or_id)
          if Code.ensure_loaded?(mod) and function_exported?(mod, :id, 0), do: mod, else: SuperPi.Harness.Default
        rescue
          _ -> SuperPi.Harness.Default
        end

      mod ->
        mod
    end
  end

  def resolve(_), do: SuperPi.Harness.Default
end
