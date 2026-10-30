defmodule SuperPi.Plugins.AutoCommit do
  @moduledoc """
  Auto-Commit Plugin (migrated from Pi ecosystem `auto-commit-on-exit.ts`).

  Automatically checks for uncommitted git changes when an agent turn completes (`after_run/2`),
  and creates an atomic git commit if repository changes are detected.

  ### Configuration Options (`ctx[:config]` or harness tuple):
  - `:enabled` - Boolean to toggle auto-commit behavior (default: `true`).
  - `:commit_prefix` - Prefix string for generated commit messages (default: `"[super-pi]"`).
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
    config = Map.get(ctx, :config, [])
    enabled? = get_config(config, :enabled, true)

    if enabled? do
      perform_commit(summary, ctx, config)
    else
      :accept
    end
  end

  defp perform_commit(summary, ctx, config) do
    ws = Map.get(ctx, :workspace_root, File.cwd!())
    prefix = get_config(config, :commit_prefix, "[super-pi]")

    if merge_in_progress?(ws) do
      Logger.debug("[AutoCommit] Merge in progress with unmerged files; skipping auto-commit")
      :accept
    else
      do_perform_commit(ws, summary, prefix)
    end
  rescue
    _ -> :accept
  end

  defp merge_in_progress?(ws) do
    File.exists?(Path.join(ws, ".git/MERGE_HEAD")) or
      case System.cmd("git", ["rev-parse", "-q", "--verify", "MERGE_HEAD"],
             cd: ws,
             stderr_to_stdout: true
           ) do
        {_, 0} -> true
        _ -> false
      end
  end

  defp do_perform_commit(ws, summary, prefix) do
    case System.cmd("git", ["status", "--porcelain"], cd: ws, stderr_to_stdout: true) do
      {status, 0} when byte_size(status) > 0 ->
        # Stage all modifications
        System.cmd("git", ["add", "-A"], cd: ws)

        # Unstage sensitive files like .env so they are never auto-committed
        System.cmd("git", ["reset", "-q", "HEAD", "--", ".env", ".env.*"], cd: ws)

        case System.cmd("git", ["diff", "--cached", "--quiet"], cd: ws) do
          {_, 1} ->
            msg = commit_message(summary, prefix)

            case System.cmd("git", ["commit", "-m", msg], cd: ws, stderr_to_stdout: true) do
              {_out, 0} ->
                Logger.info("[AutoCommit] Successfully auto-committed changes: #{msg}")

              {err, _} ->
                Logger.debug("[AutoCommit] Commit skipped or failed: #{String.trim(err)}")
            end

          _ ->
            :ok
        end

      _ ->
        :ok
    end

    :accept
  end

  defp commit_message(summary, prefix) do
    assistant_text =
      Map.get(summary, :last_assistant_text) ||
        extract_last_message_text(summary)

    case assistant_text do
      text when is_binary(text) and byte_size(text) > 0 ->
        first_line = text |> String.split("\n", parts: 2) |> hd() |> String.trim()
        trimmed = String.slice(first_line, 0, 72)
        "#{prefix} #{trimmed}"

      _ ->
        "#{prefix} Agent automated modifications"
    end
  end

  defp extract_last_message_text(summary) do
    case Map.get(summary, :last_message) || Map.get(summary, "last_message") do
      %{"content" => blocks} when is_list(blocks) ->
        Enum.find_value(blocks, fn
          %{"type" => "text", "text" => t} -> t
          %{type: "text", text: t} -> t
          _ -> nil
        end)

      %{content: blocks} when is_list(blocks) ->
        Enum.find_value(blocks, fn
          %{"type" => "text", "text" => t} -> t
          %{type: "text", text: t} -> t
          _ -> nil
        end)

      _ ->
        nil
    end
  end

  defp get_config(config, key, default) when is_map(config) do
    case Map.fetch(config, key) do
      {:ok, val} ->
        val

      :error ->
        case Map.fetch(config, to_string(key)) do
          {:ok, val} -> val
          :error -> default
        end
    end
  end

  defp get_config(config, key, default) when is_list(config) do
    Keyword.get(config, key, default)
  end

  defp get_config(_config, _key, default), do: default
end
