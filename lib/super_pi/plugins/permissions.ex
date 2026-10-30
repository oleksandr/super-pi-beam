defmodule SuperPi.Plugins.Permissions do
  @moduledoc """
  Permissions, Execution Modes, & Workspace Confinement Plugin (`SuperPi.Extension` behaviour).

  Enforces execution modes and workspace boundaries:
  - **`dangerouslySkipPermissions: true`**: Auto-approves all tool executions without prompting.
  - **`executionMode: "plan"`**: Allows read-only inspection tools (`read`, `grep`, `find`, `ls`, `tool_search`)
    and blocks mutating or side-effecting tools (`write`, `edit`, `bash`).
  - **`executionMode: "accept-edits"`**: Allows `read`, `write`, `edit`, `grep`, `find`, `ls` inside trusted workspaces
    and checks `permissions.allow` (`command(...)` entries in `settings.json`) for `bash` commands.
  - **`allowNonWorkspaceAccess`**: Defaults to `false`. File tools may only touch `workspacePaths` and
    `trustedWorkspaces`. Set it to `true` to lift the confinement.

  ## Policy

  Policy is data. It merges, lowest priority first, from:

  1. `config :super_pi, :permissions, ...` (keys such as `allowNonWorkspaceAccess`, `permissions`)
  2. `<app data dir>/settings.json`
  3. the session's `settingsOverride`

  `permissions.deny` and `permissions.allow` hold `command(...)` patterns. A `deny` match blocks
  a shell command in every mode. `allow` opens commands in `accept-edits` mode.

  ## Modes for remote callers

  A Gateway, RPC or MCP caller can request a mode. `remote_mode/1` limits the request:

      config :super_pi, :permissions,
        remote_default_mode: "accept-edits",
        remote_max_mode: "accept-edits"

  A request may select any mode up to `remote_max_mode` (`plan` < `accept-edits` < `auto`).
  The ceiling defaults to the default mode, so a request can only tighten the mode unless
  config raises the ceiling. `sanitize_remote_agent/1` also removes keys that would let a
  remote caller lift the policy (`dangerouslySkipPermissions`, `settingsOverride`, paths).
  """

  use SuperPi.Extension

  def id, do: "permissions"
  def name, do: "Execution Permissions & Workspace Boundary Shield"
  def description, do: "Enforces execution modes (plan, auto, accept-edits), command allowlists, and workspace boundary confinement"

  alias SuperPi.Discovery
  alias SuperPi.Durable.Doc

  @read_only_tools ["read", "grep", "find", "ls", "tool_search"]
  @edit_tools ["write", "edit"]
  @path_tools ["read", "write", "edit", "grep", "find", "ls", "read_file", "write_file", "edit_file", "search_files"]
  @list_tools ["grep", "find", "ls", "search_files"]
  @max_symlink_hops 40
  @mode_rank %{"plan" => 0, "accept-edits" => 1, "auto" => 2}
  @remote_forbidden_keys ["dangerouslySkipPermissions", "settingsOverride", "workspacePaths", "appDataDir", "globalConfigDir"]

  @doc """
  Returns the mode that a remote caller gets for a request.

  `requested` is the mode that the caller asked for, or `nil`. An unknown or missing value gives
  `remote_default_mode`. A value above `remote_max_mode` is lowered to it.
  """
  @spec remote_mode(term()) :: String.t()
  def remote_mode(requested \\ nil) do
    default = policy_mode(:remote_default_mode, "accept-edits")
    ceiling = policy_mode(:remote_max_mode, default)
    mode = normalize_mode(requested) || default
    if rank(mode) <= rank(ceiling), do: mode, else: ceiling
  end

  @doc """
  Removes the keys from a client-supplied agent map that would lift the permission policy,
  and limits `executionMode` with `remote_mode/1`.
  """
  @spec sanitize_remote_agent(map()) :: map()
  def sanitize_remote_agent(agent) when is_map(agent) do
    agent = Map.drop(agent, @remote_forbidden_keys)

    case Map.fetch(agent, "executionMode") do
      {:ok, requested} -> Map.put(agent, "executionMode", remote_mode(requested))
      :error -> agent
    end
  end

  @doc """
  Sets `executionMode` in `agent_cfg` for a remote caller.

  With `requested` of `nil`, the harness default is limited to the ceiling. A harness default
  that is not a permission mode (for example `"interactive"`) is left as it is.
  """
  @spec apply_remote_mode(map(), term()) :: map()
  def apply_remote_mode(agent_cfg, requested) when is_map(agent_cfg) do
    cond do
      normalize_mode(requested) != nil ->
        Map.put(agent_cfg, "executionMode", remote_mode(requested))

      normalize_mode(Map.get(agent_cfg, "executionMode")) != nil ->
        Map.put(agent_cfg, "executionMode", remote_mode(Map.get(agent_cfg, "executionMode")))

      true ->
        agent_cfg
    end
  end

  defp normalize_mode(mode) when is_binary(mode) do
    m = mode |> String.trim() |> String.downcase()
    if Map.has_key?(@mode_rank, m), do: m
  end

  defp normalize_mode(_), do: nil

  defp rank(mode), do: Map.fetch!(@mode_rank, mode)

  defp policy_mode(key, fallback) do
    case Application.get_env(:super_pi, :permissions, []) do
      cfg when is_list(cfg) or is_map(cfg) -> normalize_mode(Access.get(cfg, key)) || fallback
      _ -> fallback
    end
  end

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

      tool_name in ["bash", "run_command"] and command_denied?(args, settings) ->
        {:block, "Command is blocked by `permissions.deny`."}

      mode == "plan" and tool_name not in @read_only_tools ->
        {:block, "Tool `#{tool_name}` is blocked in `--mode plan` (read-only planning mode)."}

      not allowed_by_workspace_boundary?(tool_name, args, agent_cfg, settings) ->
        {:block, "Path access outside trusted workspaces is disabled (`allowNonWorkspaceAccess: false`)."}

      tool_name in @read_only_tools ->
        :allow

      tool_name in @edit_tools and mode in ["auto", "accept-edits"] ->
        :allow

      tool_name in ["bash", "run_command"] ->
        cmd_str = command_string(args)
        allow_list = permission_list(settings, "allow")

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

  defp command_string(args) do
    Map.get(args, "command") || Map.get(args, "cmd") ||
      Map.get(args, "CommandLine") || Map.get(args, :command) ||
      Map.get(args, :cmd) || ""
  end

  defp permission_list(settings, key) do
    case Map.get(settings, "permissions") do
      %{} = p -> Map.get(p, key, []) || []
      _ -> []
    end
  end

  defp command_denied?(args, settings) do
    cmd = command_string(args)
    is_binary(cmd) and command_matches?(cmd, permission_list(settings, "deny"))
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

  # Deny matching is conservative. The command and each pattern are cut into words at whitespace,
  # shell operators, quotes, `$(`, backticks, `/` and braces. A deny pattern matches when its
  # words appear in a row anywhere in the command. So `command(curl)` blocks `curl x`, `sudo curl x`,
  # `/usr/bin/curl x`, `echo hi && curl x`, `$(curl x)` and `bash -c 'curl x'`. It also blocks
  # `echo curl`. It does not block `curlish`. This is a guard against mistakes, not a sandbox.
  defp command_matches?(cmd, deny_list) when is_binary(cmd) and is_list(deny_list) do
    words = command_words(cmd)

    Enum.any?(deny_list, fn
      "command(" <> rest ->
        pattern = rest |> String.trim_trailing(")") |> command_words()
        pattern != [] and contains_run?(words, pattern)

      _ ->
        false
    end)
  end

  defp command_matches?(_cmd, _list), do: false

  defp command_words(text), do: String.split(text, ~r/[\s;&|()<>`$"'\\\/{}]+/, trim: true)

  defp contains_run?(words, pattern) do
    words |> Enum.chunk_every(length(pattern), 1, :discard) |> Enum.member?(pattern)
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
    app_policy = app_policy()
    app_policy |> Map.merge(file_settings) |> Map.merge(session_override)
  end

  defp app_policy do
    case Application.get_env(:super_pi, :permissions, []) do
      cfg when is_list(cfg) -> cfg |> Map.new(fn {k, v} -> {to_string(k), v} end)
      cfg when is_map(cfg) -> Map.new(cfg, fn {k, v} -> {to_string(k), v} end)
      _ -> %{}
    end
  end

  defp allowed_by_workspace_boundary?(tool_name, args, agent_cfg, settings) do
    allow_non_ws? = Map.get(settings, "allowNonWorkspaceAccess", false) == true

    if allow_non_ws? or tool_name not in @path_tools do
      true
    else
      raw_path =
        Map.get(args, "path") || Map.get(args, "file_path") ||
        Map.get(args, "dir") || Map.get(args, "directory") ||
        Map.get(args, :path) || Map.get(args, :file_path) ||
        Map.get(args, :dir) || Map.get(args, :directory)

      raw_path =
        if (not is_binary(raw_path) or raw_path == "") and tool_name in @list_tools, do: ".", else: raw_path

      if not is_binary(raw_path) or raw_path == "" do
        false
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

  # Resolves a path the way the operating system does: one component at a time, following each
  # symlink before a later `..` is applied. Collapsing `..` first (as `Path.expand/1` does) would
  # treat `<workspace>/link/..` as `<workspace>` when `link` leads outside the workspace.
  @doc """
  True when `path` is `root` or inside it, after following symlinks component by component.
  Both must be absolute. A link inside `root` that points outside it is not inside.
  """
  @spec within?(String.t(), String.t()) :: boolean()
  def within?(path, root) when is_binary(path) and is_binary(root) do
    real_target = real_path(path)
    real_root = real_path(root)
    real_root == "/" or real_target == real_root or String.starts_with?(real_target, real_root <> "/")
  end

  defp real_path(path) when is_binary(path) do
    path = if String.starts_with?(path, "~"), do: Path.expand(path), else: path
    absolute = if Path.type(path) == :absolute, do: path, else: Path.join(File.cwd!(), path)
    walk(Path.split(absolute), [], @max_symlink_hops)
  end

  defp real_path(_), do: ""

  # `resolved` holds the resolved components in reverse order. `hops` bounds symlink loops.
  defp walk([], resolved, _hops), do: join_resolved(resolved)
  defp walk(["/" | rest], _resolved, hops), do: walk(rest, ["/"], hops)
  defp walk(["." | rest], resolved, hops), do: walk(rest, resolved, hops)
  defp walk([".." | rest], ["/"] = resolved, hops), do: walk(rest, resolved, hops)
  defp walk([".." | rest], [_ | up], hops), do: walk(rest, up, hops)
  defp walk([".." | rest], [], hops), do: walk(rest, [], hops)

  defp walk([name | rest], resolved, hops) do
    candidate = join_resolved([name | resolved])

    case File.read_link(candidate) do
      {:ok, _target} when hops <= 0 ->
        join_resolved([name | resolved]) <> maybe_rest(rest)

      {:ok, target} ->
        # An absolute target starts with "/", which resets `resolved`. A relative one continues
        # from the directory that holds the link.
        walk(Path.split(target) ++ rest, resolved, hops - 1)

      _ ->
        walk(rest, [name | resolved], hops)
    end
  end

  defp maybe_rest([]), do: ""
  defp maybe_rest(rest), do: "/" <> Path.join(rest)

  defp join_resolved(resolved), do: resolved |> Enum.reverse() |> Path.join()
end
