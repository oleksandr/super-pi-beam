defmodule SuperPi.AGY.Extensions.Permissions do
  @moduledoc """
  Antigravity Permissions, Execution Mode, & Workspace Boundary Extension (`SuperPi.Extension` behaviour).

  Implements exact `agy` permission semantics (`settings.json` + CLI flags):
  - **`--dangerously-skip-permissions`**: Auto-approves all tool executions without prompting.
  - **`--mode plan`**: Allows read-only inspection tools (`read`, `grep`, `find`, `ls`, `tool_search`)
    and blocks mutating or side-effecting tools (`write`, `edit`, `bash`).
  - **`--mode accept-edits`**: Allows `read`, `write`, `edit`, `grep`, `find`, `ls` inside trusted workspaces
    and checks `permissions.allow` (`command(...)` entries in `settings.json`) for `bash` commands.
  - **`allowNonWorkspaceAccess`**: When `false`, blocks file reads/writes outside `workspacePaths` and `trustedWorkspaces`.
  """

  use SuperPi.Extension

  alias SuperPi.AGY.Discovery
  alias SuperPi.Durable.Doc

  @read_only_tools ["read", "grep", "find", "ls", "tool_search"]
  @edit_tools ["write", "edit"]

  @impl true
  def before_tool(tool_name, args, ctx) do
    agent_cfg = Doc.snapshot("conversation", ctx.conversation_id, "pi.agent") || %{}
    settings = load_effective_settings(agent_cfg)

    skip_perms? = Map.get(agent_cfg, "dangerouslySkipPermissions", false) == true
    mode = Map.get(agent_cfg, "executionMode", "auto")

    cond do
      skip_perms? ->
        :allow

      mode == "plan" and tool_name not in @read_only_tools ->
        {:block, "Tool `#{tool_name}` is blocked in `--mode plan` (read-only planning mode)."}

      not allowed_by_workspace_boundary?(tool_name, args, agent_cfg, settings) ->
        {:block, "Path access outside trusted workspaces is disabled (`allowNonWorkspaceAccess: false`)."}

      tool_name in @read_only_tools ->
        :allow

      tool_name in @edit_tools and mode in ["auto", "accept-edits"] ->
        :allow

      tool_name in ["bash", "run_command"] ->
        cmd_str = Map.get(args, "command") || Map.get(args, "CommandLine", "")
        allow_list = get_in(settings, ["permissions", "allow"]) || []

        if mode == "auto" or command_allowed?(cmd_str, allow_list) do
          :allow
        else
          {:block, "Command `#{cmd_str}` is not in `permissions.allow` under mode `#{mode}`."}
        end

      true ->
        :allow
    end
  end

  @doc """
  Checks whether a shell command matches any `command(...)` pattern in `settings.json`'s `permissions.allow` list.
  Matches exact commands (`command(git status)`) or command prefixes (`command(head)` matching `head -n 20 file.txt`).
  """
  def command_allowed?(cmd_str, allow_list) when is_binary(cmd_str) and is_list(allow_list) do
    trimmed = String.trim(cmd_str)
    first_bin = trimmed |> String.split(~r/\s+/, parts: 2) |> List.first() || ""

    Enum.any?(allow_list, fn
      "command(" <> rest ->
        pat = String.trim_trailing(rest, ")")
        trimmed == pat or first_bin == pat or String.starts_with?(trimmed, pat <> " ")

      _ ->
        false
    end)
  end

  def load_effective_settings(agent_cfg) do
    app_dir = Map.get(agent_cfg, "appDataDir", Discovery.default_app_data_dir())
    settings_path = Path.join(app_dir, "settings.json")

    file_settings =
      case File.read(settings_path) do
        {:ok, raw} ->
          case Jason.decode(raw) do
            {:ok, map} when is_map(map) -> map
            _ -> %{}
          end

        _ ->
          %{}
      end

    session_override = Map.get(agent_cfg, "settingsOverride", %{})
    Map.merge(file_settings, session_override)
  end

  defp allowed_by_workspace_boundary?(tool_name, args, agent_cfg, settings) do
    allow_non_ws? = Map.get(settings, "allowNonWorkspaceAccess", true) != false

    if allow_non_ws? or tool_name not in ["read", "write", "edit", "grep", "find", "ls"] do
      true
    else
      target_path = Map.get(args, "path", File.cwd!()) |> Path.expand()
      ws_paths = Map.get(agent_cfg, "workspacePaths", [File.cwd!()])
      trusted = Map.get(settings, "trustedWorkspaces", [])
      allowed_roots = Enum.map(ws_paths ++ trusted, &Path.expand/1)

      Enum.any?(allowed_roots, fn root ->
        target_path == root or String.starts_with?(target_path, root <> "/")
      end)
    end
  end
end
