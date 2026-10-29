defmodule SuperPi.Plugins.ProtectedPaths do
  @moduledoc """
  Protected Paths Plugin (migrated from Pi ecosystem `protected-paths.ts`).

  Blocks `write` and `edit` operations (and sensitive inspection/execution operations)
  on protected files and directories such as `.env`, `.git/`, `id_rsa`, `*.pem`, `*.key`, and credentials.

  ### Configuration Options (`ctx[:config]` or harness tuple):
  - `:patterns` - List of extra regexes or substrings to guard against.
  - `:tools` - List of tool names to inspect (default: all file & shell tools).
  - Environment variable `PROTECTED_PATHS`: Comma-separated list of additional path patterns.
  """

  use SuperPi.Extension
  require Logger

  @default_protected_patterns [
    ~r/(?:^|[\/\s"'`])\.env(?:\..+)?(?:[\/\s"'`]|}|$|\Z)/i,
    ~r/(?:^|[\/\s"'`])\.git(?:\/|[\/\s"'`]|}|$|\Z)/i,
    ~r/(?:^|[\/\s"'`])\.ssh(?:\/|[\/\s"'`]|}|$|\Z)/i,
    ~r/(?:^|[\/\s"'`])\.aws(?:\/|[\/\s"'`]|}|$|\Z)/i,
    ~r/(?:^|[\/\s"'`])\.npmrc(?:[\/\s"'`]|}|$|\Z)/i,
    ~r/(?:^|[\/\s"'`])\.netrc(?:[\/\s"'`]|}|$|\Z)/i,
    ~r/(?:^|[\/\s"'`])id_rsa(?:\.pub)?(?:[\/\s"'`]|}|$|\Z)/i,
    ~r/(?:^|[\/\s"'`])id_ed25519(?:\.pub)?(?:[\/\s"'`]|}|$|\Z)/i,
    ~r/\.pem(?:[\/\s"'`]|}|$|\Z)/i,
    ~r/\.key(?:[\/\s"'`]|}|$|\Z)/i,
    ~r/(?:^|[\/\s"'`])credentials(?:\.json|\.yml|\.yaml)?(?:[\/\s"'`]|}|$|\Z)/i
  ]

  def id, do: "protected_paths"
  def name, do: "Protected Paths Shield"
  def description, do: "Blocks modification and inspection of sensitive paths (.env, .git/, credentials)"

  @default_guarded_tools [
    "write", "edit", "read",
    "write_file", "edit_file", "read_file",
    "grep", "search_files", "ls", "find",
    "bash", "sh", "terminal", "run_command", "exec"
  ]

  @impl true
  def before_tool(tool_name, args, ctx) do
    args = if is_map(args), do: args, else: %{}
    config = Map.get(ctx, :config, [])
    guarded_tools = get_config(config, :tools, @default_guarded_tools)

    if tool_name in guarded_tools do
      cmd = Map.get(args, "command") || Map.get(args, :command) || Map.get(args, "cmd") || Map.get(args, :cmd)

      cond do
        is_binary(cmd) and cmd != "" ->
          check_command(tool_name, cmd, config)

        true ->
          path =
            Map.get(args, "path") || Map.get(args, :path) ||
            Map.get(args, "dir") || Map.get(args, :dir) ||
            Map.get(args, "file_path") || Map.get(args, :file_path) || ""

          check_path(tool_name, path, config)
      end
    else
      :allow
    end
  end

  defp check_command(tool_name, cmd, config) do
    patterns = effective_patterns(config)

    matches? =
      Enum.any?(patterns, fn
        %Regex{} = r -> Regex.match?(r, cmd)
        pat when is_binary(pat) -> String.contains?(String.downcase(cmd), String.downcase(pat))
      end)

    if matches? do
      Logger.warning("[ProtectedPaths] Blocked #{tool_name} with command referencing protected path: #{cmd}")
      {:block, "Access denied by SuperPi.Plugins.ProtectedPaths: command '#{cmd}' references a protected path."}
    else
      :allow
    end
  end

  defp check_path(tool_name, path, config) when is_binary(path) do
    if is_protected?(path, config) do
      Logger.warning("[ProtectedPaths] Blocked #{tool_name} to sensitive path: #{path}")
      {:block, "Access denied by SuperPi.Plugins.ProtectedPaths: path '#{path}' is protected."}
    else
      :allow
    end
  end

  defp check_path(_tool_name, _, _config), do: :allow

  @doc """
  Checks if a given relative or absolute path matches any protected pattern.
  Accepts either a keyword list / map config or a list of custom patterns.
  """
  def is_protected?(path, config_or_patterns \\ [])

  def is_protected?(path, patterns) when is_binary(path) and is_list(patterns) do
    normalized = String.replace(path, "\\", "/")
    effective = effective_patterns(patterns)

    matches_path? =
      Enum.any?(effective, fn
        %Regex{} = r -> Regex.match?(r, normalized)
        pat when is_binary(pat) -> String.contains?(String.downcase(normalized), String.downcase(pat))
      end)

    if matches_path? do
      true
    else
      # Check if path is a symlink or exists and its real target is protected
      case File.read_link(path) do
        {:ok, target} ->
          resolved = Path.expand(target, Path.dirname(path))
          is_protected?(resolved, patterns)

        _ ->
          false
      end
    end
  end

  def is_protected?(path, config) when is_binary(path) and is_map(config) do
    is_protected?(path, Map.to_list(config))
  end

  def is_protected?(_, _), do: false

  defp effective_patterns(opts) do
    custom =
      cond do
        is_list(opts) and Keyword.keyword?(opts) ->
          Keyword.get(opts, :patterns, [])

        is_map(opts) ->
          Map.get(opts, :patterns, Map.get(opts, "patterns", []))

        is_list(opts) ->
          opts

        true ->
          []
      end

    env_patterns =
      case System.get_env("PROTECTED_PATHS") do
        nil -> []
        "" -> []
        val ->
          val
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
      end

    @default_protected_patterns ++ custom ++ env_patterns
  end

  defp get_config(config, key, default) when is_map(config) do
    case Map.fetch(config, key) do
      {:ok, val} -> val
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
