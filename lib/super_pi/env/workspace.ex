defmodule SuperPi.Env.Workspace do
  @moduledoc """
  The workspace of a conversation: where file and command tools act.

  It is configuration, stored in the conversation's `pi.agent` document:

      "workspace" => %{"kind" => "local"}                              # default
      "workspace" => %{"kind" => "shared", "root" => "/mnt/shared/ws"}
      "workspace" => %{"kind" => "scratch"}                            # also "base", "lifetime"
      "workspace" => %{"kind" => "none"}

  | Kind | Where | Survives node loss | Capabilities |
  |---|---|---|---|
  | `local` | The disk of the node, as before (cwd and the permission policy decide). | No | `fs`, `exec`, `net` |
  | `shared` | A directory on storage that every node mounts. Paths are confined to `root`. Writes take a cross-node lock. | Yes | `fs`, `exec`, `net` |
  | `scratch` | A temporary directory on the node that runs the task, confined, removed when the task ends. `"lifetime" => "conversation"` keeps it until the sweep (`scratch_ttl_hours`, default 24). `"base"` or `config :super_pi, scratch_dir` sets the parent directory. | No | `fs`, `exec`, `net` |
  | `none` | No filesystem or commands. The agent has the artifact tools, MCP tools and the web. | n/a | `net` |

  ## Network

  `net` is on in every kind. `"network" => false` in the workspace map removes it, so a deployment
  can run an agent that reads a repository and cannot make outgoing calls: web, MCP and every other
  tool that declares a `net_read` or `net_write` effect is then not offered and is refused if called.
  This differs from `Permissions` (`network: "deny"`): the workspace decides whether the model is
  shown a network tool, the policy decides whether one call is allowed.

  ## Capability of a tool

  A tool states its effects (`SuperPi.Tools.effects/2`) and the effects give the capability:
  `fs_write` needs `fs`, `exec` needs `exec`, `net_read` and `net_write` need `net`, `read` and
  `state_write` need nothing. The built-in file and shell tools are matched by name, because `read`
  is also the effect of tools that read Super-Pi state. Artifact tools need `artifacts`. A tool that
  states no effects needs `fs`, `exec` and `net`, so an unknown tool is not offered where any of
  them is missing.

  Artifact tools (`SuperPi.Artifacts`) are offered with `shared`, `scratch` and `none`, and with
  `local` when the workspace sets `"artifacts" => true`. A tool whose capability the workspace
  does not have is not offered and is refused if called. The tools never fall back to the local
  disk: a `shared` workspace without a `root` is an error.

  Confinement of `shared` and `scratch` follows symlinks, so a link inside the workspace cannot
  lead out of it. It applies to file tools. A shell command runs with the root as its working
  directory but is not sandboxed by this module; use an OS-level sandbox for untrusted commands.
  """

  alias SuperPi.Durable.Doc
  alias SuperPi.Plugins.Permissions

  @enforce_keys [:kind]
  defstruct [:kind, :root, :env, capabilities: [], artifacts?: false, notice: nil, confined?: false]

  @type t :: %__MODULE__{}

  @file_tools ~w(read read_file write write_file edit edit_file grep search_files find find_files ls list_dir list_directory)
  @exec_tools ~w(bash sh terminal run_command exec)

  @doc "Resolves the workspace for a tool call. `ctx` has `:conversation_id` and, in a turn, `:active_task_id`."
  @spec resolve(map()) :: {:ok, t()} | {:error, String.t()}
  def resolve(ctx) do
    agent =
      case Map.get(ctx, :conversation_id) do
        nil -> %{}
        id -> Doc.snapshot("conversation", id, "pi.agent") || %{}
      end

    build(Map.get(agent, "workspace") || %{"kind" => "local"}, ctx)
  end

  @doc "Resolves a workspace from its configuration map."
  def build(cfg, ctx \\ %{})

  def build(%{"kind" => "local"} = cfg, _ctx) do
    {:ok, %__MODULE__{kind: "local", env: SuperPi.Env.Local, capabilities: caps(cfg, [:fs, :exec]), artifacts?: cfg["artifacts"] == true}}
  end

  def build(%{"kind" => "shared"} = cfg, _ctx) do
    case cfg["root"] do
      root when is_binary(root) and root != "" ->
        if Path.type(root) == :absolute do
          {:ok, %__MODULE__{kind: "shared", root: root, env: SuperPi.Env.Shared, capabilities: caps(cfg, [:fs, :exec]), artifacts?: true, confined?: true}}
        else
          {:error, "workspace kind shared needs an absolute root, got #{inspect(root)}"}
        end

      _ ->
        {:error, "workspace kind shared needs a root directory"}
    end
  end

  def build(%{"kind" => "scratch"} = cfg, ctx) do
    base = cfg["base"] || Application.get_env(:super_pi, :scratch_dir, Path.join(System.tmp_dir!(), "super_pi_scratch"))
    conv = Map.get(ctx, :conversation_id) || "none"

    {dir, notice_if_new} =
      case {cfg["lifetime"], Map.get(ctx, :active_task_id)} do
        {"conversation", _} -> {Path.join([base, to_string(conv), "_conversation"]), nil}
        {_, nil} -> {Path.join([base, to_string(conv), "_no_task"]), nil}
        {_, task_id} -> {Path.join([base, to_string(conv), "task-#{task_id}"]), restart_notice(task_id)}
      end

    fresh? = not File.dir?(dir)

    case File.mkdir_p(dir) do
      :ok ->
        notice = if fresh? and notice_if_new, do: notice_if_new, else: nil
        {:ok, %__MODULE__{kind: "scratch", root: dir, env: SuperPi.Env.Local, capabilities: caps(cfg, [:fs, :exec]), artifacts?: true, confined?: true, notice: notice}}

      {:error, reason} ->
        {:error, "cannot create the scratch workspace #{dir}: #{:file.format_error(reason)}"}
    end
  end

  def build(%{"kind" => "none"} = cfg, _ctx) do
    {:ok, %__MODULE__{kind: "none", capabilities: caps(cfg, []), artifacts?: true}}
  end

  def build(%{"kind" => kind}, _ctx), do: {:error, "unknown workspace kind #{inspect(kind)} (local, shared, scratch, none)"}
  def build(other, _ctx), do: {:error, "workspace must be a map with a kind, got #{inspect(other)}"}

  # `:net` is on unless the workspace says `"network" => false`.
  defp caps(%{"network" => false}, base), do: base
  defp caps(_cfg, base), do: base ++ [:net]

  # A task that ran before (a restart or a failover) lost its scratch files.
  defp restart_notice(task_id) do
    case SuperPi.Repo.get(SuperPi.Durable.Schemas.Task, task_id) do
      %{attempt: attempt} when is_integer(attempt) and attempt > 0 ->
        "[workspace] This task restarted, so its scratch workspace is new and empty. Earlier files are gone. Restore what you saved with artifact_get."

      _ ->
        nil
    end
  end

  @doc """
  Capabilities a tool needs, all of them: a list of `:fs`, `:exec`, `:net` or `:artifacts`.
  `agent_cfg` supplies the tool's declared effects (`SuperPi.Tools.effects/2`). See the module doc.
  """
  @spec required_capabilities(String.t(), map() | nil) :: [atom()]
  def required_capabilities(tool, agent_cfg \\ nil)
  def required_capabilities(tool, _cfg) when tool in @file_tools, do: [:fs]
  def required_capabilities(tool, _cfg) when tool in @exec_tools, do: [:exec]
  def required_capabilities("artifact_" <> _, _cfg), do: [:artifacts]

  def required_capabilities(tool, agent_cfg) do
    case SuperPi.Tools.effects(tool, agent_cfg) do
      nil -> [:fs, :exec, :net]
      effects -> effects |> Enum.flat_map(&effect_capabilities/1) |> Enum.uniq()
    end
  end

  defp effect_capabilities("fs_write"), do: [:fs]
  defp effect_capabilities("exec"), do: [:exec]
  defp effect_capabilities(e) when e in ["net_read", "net_write"], do: [:net]
  defp effect_capabilities(_), do: []

  @doc "First capability a tool needs, or `nil`. Kept for callers that ask about one capability."
  def capability_for(tool, agent_cfg \\ nil), do: tool |> required_capabilities(agent_cfg) |> List.first()

  @doc "True when the workspace can serve the tool."
  def supports?(%__MODULE__{} = ws, tool, agent_cfg \\ nil) do
    Enum.all?(required_capabilities(tool, agent_cfg), fn
      :artifacts -> ws.artifacts?
      cap -> cap in ws.capabilities
    end)
  end

  @doc """
  The tool list to offer a conversation: tools the workspace cannot serve are removed and the
  artifact tools are added when the workspace has them. Safe to call on every request.
  """
  @spec offered_tools([map()], map()) :: [map()]
  def offered_tools(tools, agent_cfg) when is_list(tools) do
    case build(Map.get(agent_cfg, "workspace") || %{"kind" => "local"}, %{}) do
      {:ok, ws} ->
        kept = Enum.filter(tools, &supports?(ws, &1["name"], %{"tools" => tools}))
        have = MapSet.new(kept, & &1["name"])
        extra = if ws.artifacts?, do: Enum.reject(SuperPi.Artifacts.tool_specs(), &MapSet.member?(have, &1["name"])), else: []
        kept ++ extra

      {:error, _} ->
        tools
    end
  end

  @doc """
  Absolute path for `path` inside a confined workspace. A relative path is joined to `base` (the
  root, or a `cd` inside it). Raises `throw({:workspace_error, message})` for a path outside the root.
  """
  def contain!(%__MODULE__{root: root}, path, base \\ nil) do
    base = if is_binary(base) and base != "", do: Path.expand(base, root), else: root
    abs = Path.expand(path, base)

    if Permissions.within?(abs, root),
      do: abs,
      else: throw({:workspace_error, "path #{path} is outside the workspace #{root}"})
  end

  # --- Scratch lifecycle ---

  @doc "Removes the scratch directory of a finished task."
  def cleanup_scratch(conversation_id, task_id) when is_integer(task_id) do
    agent = Doc.snapshot("conversation", conversation_id, "pi.agent") || %{}

    case agent["workspace"] do
      %{"kind" => "scratch", "lifetime" => "conversation"} ->
        :ok

      %{"kind" => "scratch"} = cfg ->
        base = cfg["base"] || Application.get_env(:super_pi, :scratch_dir, Path.join(System.tmp_dir!(), "super_pi_scratch"))
        File.rm_rf(Path.join([base, to_string(conversation_id), "task-#{task_id}"]))
        :ok

      _ ->
        :ok
    end
  end

  def cleanup_scratch(_conversation_id, _task_id), do: :ok

  @doc """
  Removes scratch directories that nothing needs: the directory of a task that is no longer
  running, and any directory idle longer than `scratch_ttl_hours` (default 24). Returns the number
  of directories removed.
  """
  def sweep(base \\ nil) do
    base = base || Application.get_env(:super_pi, :scratch_dir, Path.join(System.tmp_dir!(), "super_pi_scratch"))
    ttl = Application.get_env(:super_pi, :scratch_ttl_hours, 24) * 3600
    now = System.os_time(:second)

    for conv_dir <- ls_dirs(base), dir <- ls_dirs(conv_dir), stale?(dir, now, ttl), reduce: 0 do
      acc ->
        File.rm_rf(dir)
        acc + 1
    end
  end

  defp stale?(dir, now, ttl) do
    name = Path.basename(dir)

    task_gone? =
      case Regex.run(~r/\Atask-(\d+)\z/, name) do
        [_, id] ->
          case SuperPi.Repo.get(SuperPi.Durable.Schemas.Task, String.to_integer(id)) do
            nil -> true
            task -> SuperPi.Durable.Schemas.Task.terminal?(task)
          end

        _ ->
          false
      end

    old? =
      case File.stat(dir, time: :posix) do
        {:ok, %{mtime: mtime}} -> now - mtime > ttl
        _ -> false
      end

    task_gone? or old?
  end

  defp ls_dirs(dir) do
    case File.ls(dir) do
      {:ok, names} -> names |> Enum.map(&Path.join(dir, &1)) |> Enum.filter(&File.dir?/1)
      _ -> []
    end
  end
end
