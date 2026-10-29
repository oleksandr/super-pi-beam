defmodule SuperPi.Plugins.ConfirmDestructive do
  @moduledoc """
  Confirm Destructive Actions Plugin (migrated from Pi ecosystem `confirm-destructive.ts`).

  Intercepts dangerous tool operations (`rm -rf`, `DROP TABLE`, `git reset --hard`)
  in `before_tool/3` and blocks unauthorized destructive executions.

  ### Configuration Options (`ctx[:config]` or harness tuple):
  - `:blocked_patterns` - List of extra regexes or command substrings to block.
  - `:tools` - Tools to guard (default: `["bash"]`).
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
  def before_tool(tool_name, args, ctx) do
    config = Map.get(ctx, :config, [])
    guarded_tools = Keyword.get(config, :tools, ["bash"])

    if tool_name in guarded_tools do
      cmd = Map.get(args, "command") || Map.get(args, :command) || ""
      check_command(cmd, config)
    else
      :allow
    end
  end

  defp check_command(cmd, config) when is_binary(cmd) do
    patterns = effective_patterns(config)

    if Enum.any?(patterns, fn
      %Regex{} = r -> Regex.match?(r, cmd)
      pat when is_binary(pat) -> String.contains?(cmd, pat)
    end) do
      Logger.warning("[ConfirmDestructive] Blocked destructive bash execution: #{cmd}")
      {:block, "Destructive operation intercepted by SuperPi.Plugins.ConfirmDestructive: '#{cmd}'. User confirmation required."}
    else
      :allow
    end
  end

  defp check_command(_, _config), do: :allow

  defp effective_patterns(opts) do
    custom =
      case opts do
        list when is_list(list) ->
          if Keyword.keyword?(list) do
            Keyword.get(list, :blocked_patterns, [])
          else
            list
          end

        map when is_map(map) ->
          Map.get(map, :blocked_patterns, [])

        _ ->
          []
      end

    @destructive_patterns ++ custom
  end
end
