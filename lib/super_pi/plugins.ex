defmodule SuperPi.Plugins do
  @moduledoc """
  Plugin Registry & Dispatcher for Super-Pi-BEAM.

  Plugins are reusable, modular extensions implementing `SuperPi.Extension` (all 12 lifecycle hooks).
  They can be assembled declaratively into any harness, configured dynamically in sessions,
  or loaded via CLI/OpenCode options.
  """

  alias SuperPi.Plugins.{
    AutoCommit,
    ConfirmDestructive,
    CustomCompaction,
    GitCheckpoint,
    Handoff,
    InlineBash,
    JevRouter,
    PromptCustomizer,
    ProtectedPaths,
    Questionnaire,
    StructuredOutput,
    Subagent,
    Todo
  }

  @built_in_plugins [
    AutoCommit,
    ConfirmDestructive,
    CustomCompaction,
    GitCheckpoint,
    Handoff,
    InlineBash,
    JevRouter,
    PromptCustomizer,
    ProtectedPaths,
    Questionnaire,
    StructuredOutput,
    Subagent,
    Todo
  ]

  @aliases %{
    "auto_commit" => AutoCommit,
    "auto-commit" => AutoCommit,
    "confirm_destructive" => ConfirmDestructive,
    "confirm-destructive" => ConfirmDestructive,
    "custom_compaction" => CustomCompaction,
    "custom-compaction" => CustomCompaction,
    "git_checkpoint" => GitCheckpoint,
    "git-checkpoint" => GitCheckpoint,
    "handoff" => Handoff,
    "inline_bash" => InlineBash,
    "inline-bash" => InlineBash,
    "jev_router" => JevRouter,
    "jev-router" => JevRouter,
    "prompt_customizer" => PromptCustomizer,
    "prompt-customizer" => PromptCustomizer,
    "protected_paths" => ProtectedPaths,
    "protected-paths" => ProtectedPaths,
    "questionnaire" => Questionnaire,
    "structured_output" => StructuredOutput,
    "structured-output" => StructuredOutput,
    "subagent" => Subagent,
    "todo" => Todo
  }

  @doc """
  Returns the list of available built-in plugin modules.
  """
  def list, do: @built_in_plugins

  @doc """
  Returns structured catalog metadata for all registered plugins.
  """
  def catalog do
    Enum.map(@built_in_plugins, fn mod ->
      %{
        id: mod.id(),
        name: mod.name(),
        description: mod.description(),
        module: mod
      }
    end)
  end

  @doc """
  Resolves a plugin specification (atom, string, module, or {spec, opts} tuple).
  """
  def resolve({mod_or_name, opts}) when is_list(opts) or is_map(opts) do
    case resolve(mod_or_name) do
      nil -> nil
      resolved_mod -> {resolved_mod, opts}
    end
  end

  def resolve(module) when is_atom(module) do
    _ = Code.ensure_loaded?(module)

    cond do
      function_exported?(module, :agent_defaults, 1) or function_exported?(module, :extensions, 1) ->
        nil

      module in @built_in_plugins ->
        module

      function_exported?(module, :id, 0) ->
        module

      true ->
        Map.get(@aliases, to_string(module))
    end
  end

  def resolve(name) when is_binary(name) do
    normalized = name |> String.trim() |> String.downcase()
    Map.get(@aliases, normalized)
  end

  def resolve(_), do: nil

  @doc """
  Resolves a declarative list of plugins, preserving configuration options and ignoring invalid entries.
  """
  def resolve_all(specs) when is_list(specs) do
    specs
    |> Enum.map(&resolve/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.group_by(fn
      {mod, _opts} -> mod
      mod -> mod
    end)
    |> Enum.map(fn {_mod, entries} ->
      Enum.find(entries, &is_tuple/1) || hd(entries)
    end)
  end

  def resolve_all(_), do: []
end
