defmodule SuperPi.Plugins.ConfirmDestructive do
  @moduledoc """
  Confirm Destructive Actions Plugin (migrated from Pi ecosystem `confirm-destructive.ts`).

  Intercepts dangerous tool operations (`rm -rf`, `DROP TABLE`, `git reset --hard`)
  in `before_tool/3` and blocks unauthorized destructive executions.

  ### Configuration Options (`ctx[:config]` or harness tuple):
  - `:blocked_patterns` - List of extra regexes or command substrings to block.
  - `:tools` - Tools to guard (default: all shell execution tools).
  """

  use SuperPi.Extension
  require Logger

  @destructive_patterns [
    ~r/\brm\s+.*-[a-zA-Z]*r[a-zA-Z]*f[a-zA-Z]*(?:\s|$)/i,
    ~r/\brm\s+.*-[a-zA-Z]*f[a-zA-Z]*r[a-zA-Z]*(?:\s|$)/i,
    ~r/\brm\s+.*-(?:r\s+-f|f\s+-r)\b/i,
    ~r/\brm\s+.*--(?:recursive\s+--force|force\s+--recursive)\b/i,
    ~r/\bgit\s+clean\s+-[a-zA-Z]*f[a-zA-Z]*\b/i,
    ~r/\bgit\s+reset\s+--hard\b/i,
    ~r/\bgit\s+push\s+.*(?:--force|-f\b)/i,
    ~r/\bfind\b.*-delete\b/i,
    ~r/\bDROP\s+(?:TABLE|DATABASE)\b/i,
    ~r/\bTRUNCATE\s+TABLE\b/i
  ]

  @doc """
  Plugin identifier.
  """
  def id, do: "confirm_destructive"
  def name, do: "Confirm Destructive Operations"

  def description,
    do: "Blocks catastrophic and destructive operations unless explicitly confirmed"

  @default_guarded_tools ["bash", "sh", "terminal", "run_command", "exec"]

  @impl true
  def before_tool(tool_name, args, ctx) do
    args = if is_map(args), do: args, else: %{}
    config = Map.get(ctx, :config, [])
    guarded_tools = get_config(config, :tools, @default_guarded_tools)

    if tool_name in guarded_tools do
      cmd =
        Map.get(args, "command") || Map.get(args, :command) ||
          Map.get(args, "cmd") || Map.get(args, :cmd) ||
          Map.get(args, "script") || Map.get(args, :script) || ""

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

      {:block,
       "Destructive operation blocked by SuperPi.Plugins.ConfirmDestructive: '#{cmd}' is not permitted."}
    else
      :allow
    end
  end

  defp check_command(_cmd, _config), do: :allow

  defp effective_patterns(config) do
    custom =
      cond do
        is_list(config) and Keyword.keyword?(config) ->
          Keyword.get(config, :blocked_patterns, [])

        is_map(config) ->
          Map.get(config, :blocked_patterns, Map.get(config, "blocked_patterns", []))

        true ->
          []
      end

    @destructive_patterns ++ custom
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
