defmodule SuperPi.Plugins.ProtectedPaths do
  @moduledoc """
  Protected Paths Plugin (migrated from Pi ecosystem `protected-paths.ts`).

  Blocks `write` and `edit` operations (and optionally sensitive `read` operations)
  on protected files and directories such as `.env`, `.git/`, `id_rsa`, `*.pem`, and credentials.

  ### Configuration Options (`ctx[:config]` or harness tuple):
  - `:patterns` - List of extra regexes or substrings to guard against.
  - `:tools` - List of tool names to inspect (default: `["write", "edit", "read"]`).
  - Environment variable `PROTECTED_PATHS`: Comma-separated list of additional path patterns.
  """

  use SuperPi.Extension
  require Logger

  @default_protected_patterns [
    ~r/(?:^|\/)\.env(?:\..+)?$/,
    ~r/(?:^|\/)\.git\//,
    ~r/(?:^|\/)id_rsa(?:\.pub)?$/,
    ~r/\.pem$/,
    ~r/(?:^|\/)credentials(?:\.json|\.yml|\.yaml)?$/
  ]

  def id, do: "protected_paths"
  def name, do: "Protected Paths Shield"
  def description, do: "Blocks modification and inspection of sensitive paths (.env, .git/, credentials)"

  @impl true
  def before_tool(tool_name, args, ctx) do
    config = Map.get(ctx, :config, [])
    guarded_tools = Keyword.get(config, :tools, ["write", "edit", "read"])

    if tool_name in guarded_tools do
      path = Map.get(args, "path") || Map.get(args, :path) || ""
      check_path(tool_name, path, config)
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

    Enum.any?(effective, fn
      %Regex{} = r -> Regex.match?(r, normalized)
      pat when is_binary(pat) -> String.contains?(normalized, pat)
    end)
  end

  def is_protected?(path, config) when is_binary(path) and is_map(config) do
    is_protected?(path, Map.to_list(config))
  end

  def is_protected?(_, _), do: false

  defp effective_patterns(opts) do
    custom =
      case opts do
        list when is_list(list) ->
          if Keyword.keyword?(list) do
            Keyword.get(list, :patterns, [])
          else
            list
          end

        _ ->
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
end
