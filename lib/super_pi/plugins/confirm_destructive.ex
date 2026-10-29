defmodule SuperPi.Plugins.ConfirmDestructive do
  @moduledoc """
  Confirm Destructive Actions Plugin (migrated from Pi ecosystem `confirm-destructive.ts`).

  Intercepts dangerous tool operations (`rm -rf`, `DROP TABLE`, `git reset --hard`)
  in `before_tool/3` and blocks unauthorized destructive executions.
  """

  use SuperPi.Extension
  require Logger

  @destructive_patterns [
    ~r/\brm\s+-(?:r[fF]|[fF]r)\b/,
    ~r/\bgit\s+reset\s+--hard\b/,
    ~r/\bgit\s+clean\s+-(?:f[dD]|[dD]f)\b/,
    ~r/\bDROP\s+(?:TABLE|DATABASE)\b/i,
    ~r/\bTRUNCATE\s+TABLE\b/i
  ]

  @doc """
  Plugin identifier.
  """
  def id, do: "confirm_destructive"
  def name, do: "Confirm Destructive Operations"
  def description, do: "Blocks catastrophic and destructive operations unless explicitly confirmed"

  @impl true
  def before_tool(tool_name, args, _ctx) do
    case tool_name do
      "bash" ->
        cmd = Map.get(args, "command") || Map.get(args, :command) || ""
        check_command(cmd)

      _ ->
        :allow
    end
  end

  defp check_command(cmd) when is_binary(cmd) do
    if Enum.any?(@destructive_patterns, &Regex.match?(&1, cmd)) do
      Logger.warning("[ConfirmDestructive] Blocked destructive bash execution: #{cmd}")
      {:block, "Destructive operation intercepted by SuperPi.Plugins.ConfirmDestructive: '#{cmd}'. User confirmation required."}
    else
      :allow
    end
  end

  defp check_command(_), do: :allow
end
