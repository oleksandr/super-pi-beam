defmodule SuperPi.Plugins.Subagent do
  @moduledoc """
  Subagent Orchestration Plugin (migrated from Pi ecosystem `subagent/`).

  Adds the `delegate_subagent` tool. A call starts a **child conversation** with its own model
  loop and its own context window, and returns at once. Pass `tasks` to start several children.

  ## Flow

  1. The tool creates the children and one `pi.subagent` task per child (owned by the parent's
     running task), enqueues one `SuperPi.Workers.SubagentWorker` job per child, puts the parent
     task in `waiting` (`TaskEngine.wait_for_children/4`) and returns an acknowledgement that
     names the children. Its `control` directive `%{"await" => ...}` tells the machine to park.
  2. The parent's machine parks in `:awaiting_children`. It still answers `cancel`, `get_state` and
     `compact`. The children run on any node of the cluster, under the `:subagents` queue limit.
  3. When every child has ended (`wait_policy: "all"`), or at once when one fails
     (`wait_policy: "fail_fast"`), the parent wakes. The machine appends one message per child with
     its summary and the turn goes on. The model sees the summaries as new messages in its next
     request, not as the result of the tool call.

  ## What a child gets

  - Its own durable conversation (`owner_kind: "task"`, owned by the parent's running task), so
    the work is recorded and inspectable.
  - The parent's model, workspace and settings, and a system prompt for its role.
  - **Never more permission than the parent.** The roles `scout`, `planner`, `reviewer` and
    `researcher` run the `Planner` harness: `plan` mode with read-only tools. A `worker` runs the
    `Code` harness in the parent's execution mode. Permission settings and
    `dangerouslySkipPermissions` are copied, not raised.
  - No `delegate_subagent`, `ask_question` or `handoff` tools: a child cannot spawn children
    beyond `config :super_pi, subagent_max_depth` (default 1) and has no human to ask.

  ## Limits

  - Children use the same provider and credentials as the parent. There is no separate budget.
  - A child ends at the timeout (`timeout_ms`, default `config :super_pi, subagent_timeout_ms`
    = 120 s, counted from the start of its job) and is then failed and stopped.
  - `session.cancel` on the parent aborts the whole subtree: the children's tasks are aborted and
    their machines stop.
  - One delegation at a time: a second call while children run is refused. Give all tasks in one
    call (`tasks`).
  - Only the child's final text returns to the parent, not its intermediate steps. It is cut at
    8000 bytes.

  ## Events

  `subagent_started` when a child's job begins, `subagent_finished` when its task settles. Both go
  to the parent conversation.

  ## Tests

  `config :super_pi, :subagent_machine_opts` is merged into every child machine's options (an
  `llm_responder`). Oban runs in `testing: :manual` there: drain the `:subagents` queue to run the
  children.
  """

  use SuperPi.Extension
  alias SuperPi.Auth
  alias SuperPi.Durable.{Doc, Storage, TaskEngine}
  alias SuperPi.Harness
  alias SuperPi.Plugins.Permissions
  alias SuperPi.Workers.SubagentWorker

  def id, do: "subagent"
  def name, do: "Subagent Delegation"
  def description, do: "Delegates focused tasks to child conversations with their own model loop"

  @read_only_roles ["scout", "planner", "reviewer", "researcher"]
  @roles @read_only_roles ++ ["worker"]
  @never_in_child ["delegate_subagent", "ask_question", "handoff"]
  # Plugins that a child does not load: no delegation, no human to ask, no model switching, no VCS side effects.
  @not_in_child [
    __MODULE__,
    SuperPi.Plugins.Questionnaire,
    SuperPi.Plugins.Handoff,
    SuperPi.Plugins.JevRouter,
    SuperPi.Plugins.GitCheckpoint,
    SuperPi.Plugins.AutoCommit
  ]
  @role_harness %{
    "scout" => Harness.Planner,
    "planner" => Harness.Planner,
    "reviewer" => Harness.Planner,
    "researcher" => Harness.Planner,
    "worker" => Harness.Code
  }
  @policies %{"all" => "all_settled", "fail_fast" => "fail_fast"}

  @role_prompts %{
    "scout" =>
      "You are a scout. Explore the codebase quickly and report where things are and how they connect. Read only. Answer concisely with file paths.",
    "planner" =>
      "You are a planner. Read the relevant code and return a concrete step-by-step plan. Read only. Do not change anything.",
    "reviewer" =>
      "You are a reviewer. Read the code or change you are given and report concrete problems, ordered by severity. Read only.",
    "researcher" =>
      "You are a researcher. Investigate the question using the files available and report findings with evidence. Read only.",
    "worker" =>
      "You are a worker. Carry out the task you are given using your tools, then report what you changed and the result."
  }

  @tool_spec %{
    "name" => "delegate_subagent",
    "effects" => ["state_write"],
    "description" =>
      "Delegate focused tasks to isolated subagents. Each runs its own model loop with a fresh context window. " <>
        "Roles scout, planner, reviewer and researcher are read-only. A worker may edit, within your permissions. " <>
        "Give either `role` and `prompt`, or `tasks` (a list of role and prompt pairs) to run several at once. " <>
        "This call does not wait. It returns at once with an acknowledgement that names the subagents, and the subagents run in the background. " <>
        "Their answers are NOT in this tool result: when every subagent has ended, each answer arrives as a separate message at the start of your next turn step. " <>
        "After you call this tool, end your step. Do not call it again for the same work and do not assume the delegation produced nothing. " <>
        "Delegate all independent tasks in ONE call. With `wait_policy` \"fail_fast\" you are woken as soon as one subagent fails, and the others are stopped.",
    "parameters" => %{
      "type" => "object",
      "properties" => %{
        "role" => %{"type" => "string", "enum" => @roles, "description" => "Role of the subagent"},
        "prompt" => %{
          "type" => "string",
          "description" =>
            "Complete task description. The subagent sees nothing else from this conversation."
        },
        "tasks" => %{
          "type" => "array",
          "description" => "Several tasks to run concurrently",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "role" => %{"type" => "string", "enum" => @roles},
              "prompt" => %{"type" => "string"}
            },
            "required" => ["role", "prompt"]
          }
        },
        "wait_policy" => %{
          "type" => "string",
          "enum" => Map.keys(@policies),
          "description" =>
            "all (default): wake when every subagent has ended. fail_fast: wake at once when one fails and stop the others."
        },
        "timeout_ms" => %{
          "type" => "integer",
          "description" => "Maximum run time per subagent in milliseconds"
        }
      }
    }
  }

  @impl true
  def before_agent_start(agent_cfg, _ctx) do
    existing = Map.get(agent_cfg, "tools") || []
    depth = Map.get(agent_cfg, "subagentDepth", 0)

    if Enum.any?(existing, &(&1["name"] == "delegate_subagent")) or depth >= max_depth() do
      {:ok, agent_cfg}
    else
      {:ok, Map.put(agent_cfg, "tools", existing ++ [@tool_spec])}
    end
  end

  @impl true
  def wrap_tool("delegate_subagent", _args, _next, ctx)
      when not is_map_key(ctx, :conversation_id) do
    error("delegate_subagent needs a conversation context.", "invalid_context")
  end

  def wrap_tool("delegate_subagent", args, _next, ctx) do
    parent_agent = Doc.snapshot("conversation", ctx.conversation_id, "pi.agent") || %{}
    depth = Map.get(parent_agent, "subagentDepth", 0)

    with :ok <- check_depth(depth),
         {:ok, tasks, timeout_ms, policy} <- parse_args(args, Map.get(ctx, :config)),
         {:ok, parent_task_id} <- require_task(ctx),
         :ok <- check_idle(parent_task_id),
         {:ok, children} <- start_children(tasks, timeout_ms, parent_agent, parent_task_id, ctx),
         :ok <- park_parent(parent_task_id, children, policy) do
      acknowledge(children, policy)
    else
      {:error, status, message} -> error(message, status)
    end
  end

  def wrap_tool(_name, args, next, _ctx), do: next.(args)

  @doc "Returns the tool specification map for direct registration."
  def tool_spec, do: @tool_spec

  @doc false
  # The extensions a child of this role loads (see `SubagentWorker.machine_opts/1`).
  def child_extensions(role) do
    Enum.reject(Harness.remote_extensions(Map.fetch!(@role_harness, role)), fn ext ->
      mod = if is_tuple(ext), do: elem(ext, 0), else: ext
      mod in @not_in_child
    end)
  end

  # --- Arguments ---

  defp check_depth(depth) do
    if depth >= max_depth(),
      do: {:error, "depth_limit", "Subagents cannot delegate further (limit #{max_depth()})."},
      else: :ok
  end

  defp parse_args(args, config) when is_map(args) do
    default_timeout =
      config_timeout(config) || Application.get_env(:super_pi, :subagent_timeout_ms, 120_000)

    # The model may shorten the timeout but never raise it above the configured limit.
    timeout_ms = min(positive_int(args["timeout_ms"]) || default_timeout, default_timeout)

    raw =
      case args do
        %{"tasks" => [_ | _] = list} -> list
        %{"role" => _, "prompt" => _} -> [Map.take(args, ["role", "prompt"])]
        _ -> []
      end

    tasks =
      Enum.map(raw, fn
        %{"role" => role, "prompt" => prompt} when is_binary(role) and is_binary(prompt) ->
          {role, String.trim(prompt)}

        _ ->
          :invalid
      end)

    policy = Map.get(@policies, Map.get(args, "wait_policy", "all"))

    cond do
      tasks == [] ->
        {:error, "invalid_arguments", "Give `role` and `prompt`, or a non-empty `tasks` list."}

      Enum.any?(tasks, &(&1 == :invalid)) ->
        {:error, "invalid_arguments", "Every task needs a string `role` and a string `prompt`."}

      Enum.any?(tasks, fn {role, prompt} -> role not in @roles or prompt == "" end) ->
        {:error, "invalid_arguments",
         "Role must be one of #{Enum.join(@roles, ", ")}, and the prompt must not be empty."}

      is_nil(policy) ->
        {:error, "invalid_arguments",
         "`wait_policy` must be one of #{@policies |> Map.keys() |> Enum.join(", ")}."}

      true ->
        {:ok, tasks, timeout_ms, policy}
    end
  end

  defp parse_args(_args, _config),
    do: {:error, "invalid_arguments", "Arguments must be an object."}

  # The harness may set `{Subagent, [timeout_ms: ...]}`.
  defp config_timeout(config) when is_list(config),
    do: positive_int(Keyword.get(config, :timeout_ms))

  defp config_timeout(%{timeout_ms: ms}), do: positive_int(ms)
  defp config_timeout(_), do: nil

  defp positive_int(n) when is_integer(n) and n > 0, do: n
  defp positive_int(_), do: nil

  # The parent waits through its running task: without one there is nothing to wake.
  defp require_task(%{active_task_id: id}) when is_integer(id), do: {:ok, id}

  defp require_task(_ctx),
    do: {:error, "invalid_context", "delegate_subagent needs a running turn."}

  # One wait per park: a second delegation would need the parent to watch two sets.
  defp check_idle(parent_task_id) do
    busy? =
      match?(%{status: "waiting"}, TaskEngine.get_task(parent_task_id)) or
        Enum.any?(TaskEngine.live_children(parent_task_id), &(&1.kind == "pi.subagent"))

    if busy?,
      do:
        {:error, "already_delegating",
         "Subagents are still running for this turn. Delegate every task in one call, and wait for their answers."},
      else: :ok
  end

  # --- Starting children ---

  # Children are created, then queued, then the parent is parked: a child that ends before the
  # parent waits is seen by `wait_for_children/4` (it does not park), so no wake-up is lost.
  defp start_children(tasks, timeout_ms, parent_agent, parent_task_id, ctx) do
    result =
      Enum.reduce_while(tasks, {:ok, []}, fn {role, prompt}, {:ok, acc} ->
        case start_child(role, prompt, timeout_ms, parent_agent, parent_task_id, ctx) do
          {:ok, child} -> {:cont, {:ok, [child | acc]}}
          {:error, reason} -> {:halt, {:error, Enum.reverse(acc), reason}}
        end
      end)

    case result do
      {:ok, children} ->
        {:ok, Enum.reverse(children)}

      {:error, started, reason} ->
        abort_children(started)
        {:error, "start_failed", "Could not start the subagents: #{inspect(reason)}"}
    end
  end

  defp start_child(role, prompt, timeout_ms, parent_agent, parent_task_id, ctx) do
    child =
      Storage.create_conversation!(
        owner_kind: "task",
        owner_task_id: parent_task_id,
        agent: child_agent(role, parent_agent),
        owner: Auth.owner(ctx.conversation_id)
      )

    input = %{"role" => role, "prompt" => prompt, "child_conversation_id" => child.id}

    with {:ok, task} <-
           TaskEngine.create_task(ctx.conversation_id, "pi.subagent", input,
             owner_task_id: parent_task_id
           ),
         # The child's machine finds its task here, to settle it when a resumed turn ends.
         _ <- Storage.configure_agent!(child.id, %{"subagentTaskId" => task.id}),
         job =
           SubagentWorker.new(%{
             "task_id" => task.id,
             "child_conversation_id" => child.id,
             "role" => role,
             "prompt" => prompt,
             "timeout_ms" => timeout_ms
           }),
         {:ok, _job} <- Oban.insert(job) do
      {:ok, %{"task_id" => task.id, "child_conversation_id" => child.id, "role" => role}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp park_parent(parent_task_id, children, policy) do
    ids = Enum.map(children, & &1["task_id"])

    case TaskEngine.wait_for_children(parent_task_id, ids, policy,
           phase: "awaiting_children",
           state: %{"children" => children}
         ) do
      {:ok, _task} ->
        :ok

      {:error, reason} ->
        abort_children(children)
        {:error, "start_failed", "Could not wait for the subagents: #{inspect(reason)}"}
    end
  end

  # A job that finds its task aborted does nothing.
  defp abort_children(children), do: Enum.each(children, &TaskEngine.abort_task!(&1["task_id"]))

  # --- Child configuration ---

  # A child never has more permission than its parent. Read-only roles run the `Planner` harness
  # (plan mode, read-only loadout, confined). A worker runs `Code` in the parent's execution mode and
  # never above the parent's ceiling.
  defp child_agent(role, parent_agent) do
    harness = Map.fetch!(@role_harness, role)
    model_opts = if model = parent_agent["model"], do: [model: model], else: []

    workspace_opts =
      if paths = parent_agent["workspacePaths"], do: [workspace_paths: paths], else: []

    defaults = harness.agent_defaults(model_opts ++ workspace_opts)

    mode =
      if role in @read_only_roles,
        do: defaults["executionMode"],
        else: Map.get(parent_agent, "executionMode", "accept-edits")

    defaults
    |> Map.merge(
      Map.take(parent_agent, [
        "workspacePaths",
        "workspace",
        "globalConfigDir",
        "appDataDir",
        "settingsOverride",
        "effort"
      ])
    )
    |> Map.put("executionMode", mode)
    |> Map.put(
      "maxExecutionMode",
      Map.get(parent_agent, "maxExecutionMode", mode) |> lower_of(mode)
    )
    |> Map.put("dangerouslySkipPermissions", parent_agent["dangerouslySkipPermissions"] == true)
    |> Map.put("subagentDepth", Map.get(parent_agent, "subagentDepth", 0) + 1)
    |> Map.put("systemSections", [%{"id" => "core", "content" => Map.fetch!(@role_prompts, role)}])
    |> Map.update!("tools", fn tools -> Enum.reject(tools, &(&1["name"] in @never_in_child)) end)
  end

  defp lower_of(a, b), do: if(Permissions.rank_of(a) <= Permissions.rank_of(b), do: a, else: b)

  defp max_depth, do: Application.get_env(:super_pi, :subagent_max_depth, 1)

  # --- Results ---

  defp acknowledge(children, policy) do
    ids = Enum.map(children, & &1["child_conversation_id"])

    list =
      Enum.map_join(children, "\n", fn c ->
        "- #{c["role"]}: child conversation #{c["child_conversation_id"]}"
      end)

    output =
      "Started #{length(children)} subagent(s) in the background. This is an acknowledgement, not their answer.\n#{list}\n" <>
        "Their answers will arrive as separate messages when #{if policy == "fail_fast", do: "one fails or all have", else: "all have"} ended. End your step now."

    %{
      "output" => output,
      "structured_output" => %{
        "subagents" => Enum.map(children, &Map.put(&1, "status", "started"))
      },
      "details" => %{
        "count" => length(children),
        "status" => "started",
        "child_conversation_ids" => ids
      },
      "is_error" => false,
      "control" => %{
        "await" => %{
          "task_ids" => Enum.map(children, & &1["task_id"]),
          "policy" => policy,
          "children" => children
        }
      }
    }
  end

  defp error(message, status) do
    %{
      "output" => message,
      "structured_output" => %{"error" => message, "status" => status},
      "details" => %{"status" => status},
      "is_error" => true
    }
  end
end
