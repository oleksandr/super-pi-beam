defmodule SuperPi.Harness.AGY.Extensions.Permissions do
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

  alias SuperPi.Harness.AGY.Discovery
  alias SuperPi.Durable.Doc

  @read_only_tools ["read", "grep", "find", "ls", "tool_search"]
  @edit_tools ["write", "edit"]

  @impl true
  def before_tool(tool_name, args, ctx) do
    agent_cfg = Doc.snapshot("conversation", ctx.conversation_id, "pi.agent") || %{}
    settings = load_effective_settings(agent_cfg)

    skip_perms? = Map.get(agent_cfg, "dangerouslySkipPermissions", false) == true
    raw_mode = Map.get(agent_cfg, "executionMode", "auto")
    mode = raw_mode |> to_string() |> String.trim() |> String.downcase()

    cond do
      skip_perms? ->
        :allow

      mode not in ["auto", "accept-edits", "plan"] ->
        {:block, "Execution mode `#{raw_mode}` is not recognized or not permitted."}

      mode == "plan" and tool_name not in @read_only_tools ->
        {:block, "Tool `#{tool_name}` is blocked in `--mode plan` (read-only planning mode)."}

      not allowed_by_workspace_boundary?(tool_name, args, agent_cfg, settings) ->
        {:block, "Path access outside trusted workspaces is disabled (`allowNonWorkspaceAccess: false`)."}

      tool_name in @read_only_tools ->
        :allow

      tool_name in @edit_tools and mode in ["auto", "accept-edits"] ->
        :allow

      tool_name in ["bash", "run_command"] ->
        cmd_str =
          Map.get(args, "command") || Map.get(args, "cmd") ||
          Map.get(args, "CommandLine") || Map.get(args, :command) ||
          Map.get(args, :cmd) || ""

        allow_list =
          case Map.get(settings, "permissions") do
            %{} = p -> Map.get(p, "allow", []) || []
            _ -> []
          end

        if mode == "auto" or command_allowed?(cmd_str, allow_list) do
          :allow
        else
          {:block, "Command `#{cmd_str}` is not in `permissions.allow` under mode `#{mode}`."}
        end

      mode == "accept-edits" ->
        {:block, "Tool `#{tool_name}` is not allowed by default in mode `accept-edits`."}

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

    Enum.any?(allow_list, fn
      "command(" <> rest ->
        pat =
          if String.ends_with?(rest, ")") do
            binary_part(rest, 0, byte_size(rest) - 1)
          else
            rest
          end

        cond do
          trimmed == pat ->
            true

          String.contains?(trimmed, ["&&", "||", ";", "|", "`", "$(", "\n"]) ->
            false

          String.starts_with?(trimmed, pat <> " ") ->
            true

          true ->
            false
        end

      _ ->
        false
    end)
  end

  def command_allowed?(_cmd_str, _allow_list), do: false

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
      raw_path =
        Map.get(args, "path") || Map.get(args, "file_path") ||
        Map.get(args, "dir") || Map.get(args, "directory") ||
        Map.get(args, :path) || Map.get(args, :file_path) ||
        Map.get(args, :dir) || Map.get(args, :directory)

      if not is_binary(raw_path) or raw_path == "" do
        true
      else
        real_target = real_path(raw_path)
        ws_paths = Map.get(agent_cfg, "workspacePaths", [File.cwd!()])
        trusted = Map.get(settings, "trustedWorkspaces", [])
        allowed_roots = Enum.map(ws_paths ++ trusted, &real_path/1)

        Enum.any?(allowed_roots, fn root ->
          root == "/" or real_target == root or String.starts_with?(real_target, root <> "/")
        end)
      end
    end
  end

  defp real_path(path) when is_binary(path) do
    expanded = Path.expand(path)
    resolve_symlinks_loop(expanded)
  end

  defp real_path(_), do: ""

  defp resolve_symlinks_loop(path) do
    case File.read_link(path) do
      {:ok, target} ->
        target =
          if Path.type(target) == :relative do
            Path.expand(Path.join(Path.dirname(path), target))
          else
            Path.expand(target)
          end

        resolve_symlinks_loop(target)

      {:error, :einval} ->
        parent = Path.dirname(path)

        if parent == path do
          path
        else
          resolved_parent = resolve_symlinks_loop(parent)
          Path.join(resolved_parent, Path.basename(path))
        end

      _ ->
        parent = Path.dirname(path)

        if parent == path do
          path
        else
          resolved_parent = resolve_symlinks_loop(parent)
          Path.join(resolved_parent, Path.basename(path))
        end
    end
  end
end
