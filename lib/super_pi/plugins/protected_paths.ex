defmodule SuperPi.Plugins.ProtectedPaths do
  @moduledoc """
  Protected Paths Plugin (migrated from Pi ecosystem `protected-paths.ts`).

  Blocks `write` and `edit` operations (and optionally sensitive `read` operations)
  on protected files and directories such as `.env`, `.git/`, `id_rsa`, `*.pem`, and credentials.
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
  def before_tool(tool_name, args, _ctx) do
    if tool_name in ["write", "edit", "read"] do
      path = Map.get(args, "path") || Map.get(args, :path) || ""
      check_path(tool_name, path)
    else
      :allow
    end
  end

  defp check_path(tool_name, path) when is_binary(path) do
    if is_protected?(path) do
      Logger.warning("[ProtectedPaths] Blocked #{tool_name} to sensitive path: #{path}")
      {:block, "Access denied by SuperPi.Plugins.ProtectedPaths: path '#{path}' is protected."}
    else
      :allow
    end
  end

  defp check_path(_tool_name, _), do: :allow

  @doc """
  Checks if a given relative or absolute path matches any protected pattern.
  """
  def is_protected?(path) when is_binary(path) do
    normalized = String.replace(path, "\\", "/")
    Enum.any?(@default_protected_patterns, &Regex.match?(&1, normalized))
  end

  def is_protected?(_), do: false
end
