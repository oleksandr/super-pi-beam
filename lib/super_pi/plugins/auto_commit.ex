defmodule SuperPi.Plugins.AutoCommit do
  @moduledoc """
  Auto-Commit Plugin (migrated from Pi ecosystem `auto-commit-on-exit.ts`).

  Automatically checks for uncommitted git changes when an agent turn completes (`after_run/2`),
  and creates an atomic git commit if repository changes are detected.
  """

  use SuperPi.Extension
  require Logger

  @doc """
  Plugin identifier.
  """
  def id, do: "auto_commit"
  def name, do: "Auto-Commit on Run Finish"
  def description, do: "Automatically commits modified files when an agent run completes"

  @impl true
  def after_run(summary, ctx) do
    ws = Map.get(ctx, :workspace_root, File.cwd!())

    case System.cmd("git", ["status", "--porcelain"], cd: ws, stderr_to_stdout: true) do
      {status, 0} when byte_size(status) > 0 ->
        # Working tree has modifications; stage and commit
        System.cmd("git", ["add", "-A"], cd: ws)

        msg =
          case Map.get(summary, :last_assistant_text) do
            text when is_binary(text) and byte_size(text) > 0 ->
              first_line = text |> String.split("\n", parts: 2) |> hd() |> String.trim()
              trimmed = String.slice(first_line, 0, 72)
              "[super-pi] #{trimmed}"

            _ ->
              "[super-pi] Agent automated modifications"
          end

        case System.cmd("git", ["commit", "-m", msg], cd: ws, stderr_to_stdout: true) do
          {_out, 0} ->
            Logger.info("[AutoCommit] Successfully auto-committed changes: #{msg}")

          {err, _} ->
            Logger.debug("[AutoCommit] Commit skipped or failed: #{String.trim(err)}")
        end

      _ ->
        :ok
    end

    :accept
  rescue
    _ -> :accept
  end
end
