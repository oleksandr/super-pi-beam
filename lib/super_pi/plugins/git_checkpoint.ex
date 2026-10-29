defmodule SuperPi.Plugins.GitCheckpoint do
  @moduledoc """
  Git Checkpoint Plugin (migrated from Pi ecosystem `git-checkpoint.ts`).

  Takes a git stash checkpoint (`git stash create`) before tools modify code files.
  Allows forks and rollbacks to restore repository state accurately.
  """

  use SuperPi.Extension
  require Logger

  @doc """
  Plugin identifier.
  """
  def id, do: "git_checkpoint"
  def name, do: "Git Checkpoint"
  def description, do: "Takes git stash checkpoints before file modifications to enable rollbacks"

  @impl true
  def before_tool(tool_name, _args, ctx) do
    if tool_name in ["write", "edit", "bash"] do
      ws = Map.get(ctx, :workspace_root, File.cwd!())
      create_checkpoint(ws, ctx)
    end

    :allow
  end

  defp create_checkpoint(ws, ctx) do
    case System.cmd("git", ["stash", "create"], cd: ws, stderr_to_stdout: true) do
      {ref, 0} ->
        trimmed = String.trim(ref)

        if byte_size(trimmed) > 0 do
          # Store the checkpoint so it remains reachable for rollbacks and is not garbage-collected
          System.cmd("git", ["stash", "store", "-m", "SuperPi Checkpoint", trimmed], cd: ws)
          Logger.debug("[GitCheckpoint] Created git checkpoint: #{trimmed} for conversation #{Map.get(ctx, :conversation_id)}")
        end

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end
end
