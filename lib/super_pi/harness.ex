defmodule SuperPi.Harness do
  @moduledoc """
  Pluggable Agent Harness Specification and Registry (`REQ-HARNESS-01`).

  Enables running Super-Pi-BEAM under distinct agent personalities and customization packs
  (Default Super-Pi, Workspace, Architecture Planner, and future custom extensions)
  uniformly across OpenCode, the OpenAI HTTP Gateway, and MCP without polluting the core engine.
  """

  @doc "Unique string identifier for the harness (e.g., 'super-pi-agent', 'super-pi-workspace')"
  @callback id() :: String.t()

  @doc "Human-readable name"
  @callback name() :: String.t()

  @doc "Short description for model listings and discovery"
  @callback description() :: String.t()

  @doc "List of SuperPi.Extension modules active in this harness"
  @callback extensions(opts :: keyword()) :: list(module() | {module(), term()})

  @doc "Default document configuration for the conversation agent"
  @callback agent_defaults(opts :: keyword()) :: map()

  @registry %{
    "default" => SuperPi.Harness.Default,
    "super-pi" => SuperPi.Harness.Default,
    "super-pi-agent" => SuperPi.Harness.Default,
    "fast" => SuperPi.Harness.Fast,
    "super-pi-fast" => SuperPi.Harness.Fast,
    "workspace" => SuperPi.Harness.Workspace,
    "super-pi-workspace" => SuperPi.Harness.Workspace,
    "planner" => SuperPi.Harness.Planner,
    "super-pi-planner" => SuperPi.Harness.Planner,
    "auto" => SuperPi.Harness.Autonomous,
    "super-pi-auto" => SuperPi.Harness.Autonomous,
    "interactive" => SuperPi.Harness.Interactive,
    "super-pi-interactive" => SuperPi.Harness.Interactive
  }

  @builtin_harnesses [
    SuperPi.Harness.Default,
    SuperPi.Harness.Fast,
    SuperPi.Harness.Autonomous,
    SuperPi.Harness.Interactive,
    SuperPi.Harness.Workspace,
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
    extra = Application.get_env(:super_pi, :extra_harnesses, [])

    (Code.ensure_loaded?(module) and function_exported?(module, :id, 0)) or
      Map.has_key?(@registry, to_string(module)) or
      Enum.member?(extra, module)
  end

  def harness?(name_or_id) when is_binary(name_or_id) do
    key =
      name_or_id
      |> String.downcase()
      |> String.replace_prefix("super-pi/", "")

    extra = Application.get_env(:super_pi, :extra_harnesses, [])

    Map.has_key?(@registry, key) or
      Enum.any?(extra, fn mod ->
        function_exported?(mod, :id, 0) and mod.id() == key
      end) or
      match_module_string?(name_or_id)
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

    extra = Application.get_env(:super_pi, :extra_harnesses, [])

    extra_match =
      Enum.find(extra, fn mod ->
        function_exported?(mod, :id, 0) and (mod.id() == key or mod.id() == name_or_id)
      end)

    cond do
      extra_match != nil ->
        extra_match

      Map.has_key?(@registry, key) ->
        Map.get(@registry, key)

      true ->
        resolve_module_string(name_or_id)
    end
  end

  def resolve(_), do: SuperPi.Harness.Default

  @doc """
  Default harness for entry points that receive no harness name (Gateway, RPC, MCP).

  Configure it with `config :super_pi, default_harness: "<harness id>"`. The default is
  `super-pi-workspace`, which carries the permission and safety plugins.
  """
  @spec default() :: module()
  def default do
    id = Application.get_env(:super_pi, :default_harness, "super-pi-workspace")

    case fetch(id) do
      {:ok, mod} -> mod
      {:error, _} -> SuperPi.Harness.Workspace
    end
  end

  @doc """
  Strict form of `resolve/1`. An unknown name is an error, not a silent `Default`.

  A deployment that wants a fallback can set `config :super_pi, fallback_harness: "<id>"`.
  """
  @spec fetch(String.t() | module()) :: {:ok, module()} | {:error, {:unknown_harness, term()}}
  def fetch(name) do
    cond do
      harness?(name) ->
        {:ok, resolve(name)}

      fallback = Application.get_env(:super_pi, :fallback_harness) ->
        if harness?(fallback), do: {:ok, resolve(fallback)}, else: {:error, {:unknown_harness, name}}

      true ->
        {:error, {:unknown_harness, name}}
    end
  end

  defp match_module_string?(str) do
    case resolve_module_string(str) do
      SuperPi.Harness.Default -> false
      _ -> true
    end
  end

  defp resolve_module_string(name_or_id) do
    candidates = [
      name_or_id,
      "Elixir." <> name_or_id
    ]

    Enum.find_value(candidates, SuperPi.Harness.Default, fn cand ->
      try do
        mod = String.to_existing_atom(cand)
        if Code.ensure_loaded?(mod) and function_exported?(mod, :id, 0), do: mod, else: nil
      rescue
        _ -> nil
      end
    end)
  end
end
