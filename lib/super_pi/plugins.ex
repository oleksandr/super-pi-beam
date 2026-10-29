defmodule SuperPi.Plugins do
  @moduledoc """
  Plugin Registry & Dispatcher for Super-Pi-BEAM.

  Plugins are reusable, modular extensions implementing `SuperPi.Extension` (all 12 lifecycle hooks).
  They can be enabled in any harness, configured dynamically in sessions, or loaded via CLI/OpenCode options.
  """

  alias SuperPi.Plugins.{AutoCommit, ConfirmDestructive, GitCheckpoint}

  @built_in_plugins [
    GitCheckpoint,
    AutoCommit,
    ConfirmDestructive
  ]

  @doc """
  Returns the list of available built-in plugins.
  """
  def list do
    @built_in_plugins
  end

  @doc """
  Resolves a plugin by its module, atom, or string name.
  """
  def resolve(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :__info__, 1) do
      module
    else
      case to_string(module) do
        "git_checkpoint" -> GitCheckpoint
        "auto_commit" -> AutoCommit
        "confirm_destructive" -> ConfirmDestructive
        _ -> nil
      end
    end
  end

  def resolve(name) when is_binary(name) do
    case String.downcase(String.trim(name)) do
      "git_checkpoint" -> GitCheckpoint
      "git-checkpoint" -> GitCheckpoint
      "auto_commit" -> AutoCommit
      "auto-commit" -> AutoCommit
      "confirm_destructive" -> ConfirmDestructive
      "confirm-destructive" -> ConfirmDestructive
      _ -> nil
    end
  end

  def resolve(_), do: nil
end
