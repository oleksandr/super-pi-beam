defmodule SuperPi.Plugins.Subagent do
  @moduledoc """
  Subagent Orchestration Plugin (migrated from Pi ecosystem `subagent/`).

  Adds the `delegate_subagent` tool. A call runs a **child conversation** with its own model
  loop and its own context window, waits for it, and returns the child's final answer to the
  parent as the tool result. Pass `tasks` to run several children concurrently.

  ## What a child gets

  - Its own durable conversation (`owner_kind: "task"`, owned by a `pi.subagent` task that is
    a child task of the parent's running task), so the work is recorded and inspectable.
  - The parent's model, workspace and settings, and a system prompt for its role.
  - **Never more permission than the parent.** The roles `scout`, `planner`, `reviewer` and
    `researcher` run in `plan` mode with read-only tools. A `worker` inherits the parent's
    execution mode and tools. Permission settings and `dangerouslySkipPermissions` are copied,
    not raised.
  - No `delegate_subagent`, `ask_question` or `handoff` tools: a child cannot spawn children
    beyond `config :super_pi, subagent_max_depth` (default 1) and has no human to ask.

  ## Limits

  - Children use the same provider and credentials as the parent. There is no separate budget.
  - The parent conversation process waits in the tool call, so a `steer` message is handled
    after the children finish. A child ends at the timeout (`timeout_ms`, default
    `config :super_pi, subagent_timeout_ms` = 120 s) and is then reported as failed.
  - `session.cancel` on the parent does not yet stop running children; the timeout does.
  - Only the child's final text returns to the parent, not its intermediate steps.

  Test hook: plugin config `[machine_opts: [llm_responder: fun]]` is passed to the child machine.
  """

  use SuperPi.Extension
  alias SuperPi.Auth
  alias SuperPi.Conversation.Machine
  alias SuperPi.Durable.{Doc, Storage, TaskEngine}
  alias SuperPi.Harness
  alias SuperPi.Tools

  def id, do: "subagent"
  def name, do: "Subagent Delegation"
  def description, do: "Delegates focused tasks to child conversations with their own model loop"

  @read_only_roles ["scout", "planner", "reviewer", "researcher"]
  @roles @read_only_roles ++ ["worker"]
  @read_only_tools ["read", "grep", "find", "ls", "tool_search"]
  @never_in_child ["delegate_subagent", "ask_question", "handoff"]
  @max_summary_chars 8_000

  @role_prompts %{
    "scout" => "You are a scout. Explore the codebase quickly and report where things are and how they connect. Read only. Answer concisely with file paths.",
    "planner" => "You are a planner. Read the relevant code and return a concrete step-by-step plan. Read only. Do not change anything.",
    "reviewer" => "You are a reviewer. Read the code or change you are given and report concrete problems, ordered by severity. Read only.",
    "researcher" => "You are a researcher. Investigate the question using the files available and report findings with evidence. Read only.",
    "worker" => "You are a worker. Carry out the task you are given using your tools, then report what you changed and the result."
  }

  @tool_spec %{
    "name" => "delegate_subagent",
    "description" =>
      "Delegate a focused task to an isolated subagent that runs its own model loop with a fresh context window and returns its final answer. " <>
        "Roles scout, planner, reviewer and researcher are read-only. A worker may edit, within your permissions. " <>
        "Give either `role` and `prompt`, or `tasks` (a list of role and prompt pairs) to run several at once. The call returns when every subagent has finished.",
    "parameters" => %{
      "type" => "object",
      "properties" => %{
        "role" => %{"type" => "string", "enum" => @roles, "description" => "Role of the subagent"},
        "prompt" => %{"type" => "string", "description" => "Complete task description. The subagent sees nothing else from this conversation."},
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
        "timeout_ms" => %{"type" => "integer", "description" => "Maximum run time per subagent in milliseconds"}
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
  def wrap_tool("delegate_subagent", _args, _next, ctx) when not is_map_key(ctx, :conversation_id) do
    error("delegate_subagent needs a conversation context.", "invalid_context")
  end

  def wrap_tool("delegate_subagent", args, _next, ctx) do
    parent_agent = Doc.snapshot("conversation", ctx.conversation_id, "pi.agent") || %{}
    depth = Map.get(parent_agent, "subagentDepth", 0)

    with :ok <- check_depth(depth),
         {:ok, tasks, timeout_ms} <- parse_args(args, Map.get(ctx, :config)) do
      run_all(tasks, timeout_ms, parent_agent, ctx)
    else
      {:error, status, message} -> error(message, status)
    end
  end

  def wrap_tool(_name, args, next, _ctx), do: next.(args)

  @doc "Returns the tool specification map for direct registration."
  def tool_spec, do: @tool_spec

  # --- Arguments ---

  defp check_depth(depth) do
    if depth >= max_depth(),
      do: {:error, "depth_limit", "Subagents cannot delegate further (limit #{max_depth()})."},
      else: :ok
  end

  defp parse_args(args, config) when is_map(args) do
    default_timeout = config_timeout(config) || Application.get_env(:super_pi, :subagent_timeout_ms, 120_000)
    timeout_ms = positive_int(args["timeout_ms"]) || default_timeout

    raw =
      case args do
        %{"tasks" => [_ | _] = list} -> list
        %{"role" => _, "prompt" => _} -> [Map.take(args, ["role", "prompt"])]
        _ -> []
      end

    tasks =
      Enum.map(raw, fn
        %{"role" => role, "prompt" => prompt} when is_binary(role) and is_binary(prompt) -> {role, String.trim(prompt)}
        _ -> :invalid
      end)

    cond do
      tasks == [] ->
        {:error, "invalid_arguments", "Give `role` and `prompt`, or a non-empty `tasks` list."}

      Enum.any?(tasks, &(&1 == :invalid)) ->
        {:error, "invalid_arguments", "Every task needs a string `role` and a string `prompt`."}

      Enum.any?(tasks, fn {role, prompt} -> role not in @roles or prompt == "" end) ->
        {:error, "invalid_arguments", "Role must be one of #{Enum.join(@roles, ", ")}, and the prompt must not be empty."}

      true ->
        {:ok, tasks, timeout_ms}
    end
  end

  defp parse_args(_args, _config), do: {:error, "invalid_arguments", "Arguments must be an object."}

  # The harness may set `{Subagent, [timeout_ms: ...]}`.
  defp config_timeout(config) when is_list(config), do: positive_int(Keyword.get(config, :timeout_ms))
  defp config_timeout(%{timeout_ms: ms}), do: positive_int(ms)
  defp config_timeout(_), do: nil

  defp positive_int(n) when is_integer(n) and n > 0, do: n
  defp positive_int(_), do: nil

  # --- Running children ---

  defp run_all(tasks, timeout_ms, parent_agent, ctx) do
    max_concurrency = Application.get_env(:super_pi, :subagent_max_concurrency, 3)

    results =
      tasks
      |> Task.async_stream(
        fn {role, prompt} -> run_one(role, prompt, timeout_ms, parent_agent, ctx) end,
        max_concurrency: max_concurrency,
        timeout: timeout_ms + 10_000,
        on_timeout: :kill_task,
        ordered: true
      )
      |> Enum.zip(tasks)
      |> Enum.map(fn
        {{:ok, result}, {role, _}} -> Map.put(result, "role", role)
        {{:exit, reason}, {role, _}} -> %{"role" => role, "status" => "failed", "error" => "subagent crashed: #{inspect(reason)}"}
      end)

    render(results)
  end

  defp run_one(role, prompt, timeout_ms, parent_agent, ctx) do
    parent_task_id = Map.get(ctx, :active_task_id)
    child_agent = child_agent(role, parent_agent)

    child =
      Storage.create_conversation!(
        owner_kind: if(parent_task_id, do: "task", else: "ownerless"),
        owner_task_id: parent_task_id,
        agent: child_agent
      )

    Auth.claim!(child.id, Auth.owner(ctx.conversation_id))
    task_id = start_child_task(ctx.conversation_id, parent_task_id, role, prompt, child.id)

    outcome = run_machine(child.id, prompt, timeout_ms, ctx)
    finish_child_task(task_id, outcome)

    base = %{"child_conversation_id" => child.id}

    case outcome do
      {:ok, text} -> Map.merge(base, %{"status" => "completed", "summary" => truncate(text)})
      {:error, reason} -> Map.merge(base, %{"status" => "failed", "error" => reason})
    end
  end

  defp run_machine(child_id, prompt, timeout_ms, ctx) do
    machine_opts =
      [conversation_id: child_id, extensions: child_extensions()] ++ config_machine_opts(Map.get(ctx, :config))

    spec = %{id: {:subagent, child_id}, start: {Machine, :start_link, [machine_opts]}, restart: :temporary}

    case DynamicSupervisor.start_child(SuperPi.MachineSupervisor, spec) do
      {:ok, pid} ->
        try do
          case Machine.submit(pid, prompt, timeout: timeout_ms) do
            {:ok, msg} -> {:ok, final_text(msg)}
            {:error, reason} -> {:error, format_reason(reason)}
          end
        catch
          :exit, {:timeout, _} ->
            Machine.cancel(pid)
            {:error, "timed out after #{timeout_ms} ms"}

          :exit, reason ->
            {:error, "subagent exited: #{inspect(reason)}"}
        after
          stop_machine(pid, child_id)
        end

      {:error, reason} ->
        {:error, "could not start the subagent: #{inspect(reason)}"}
    end
  end

  # Plugin config is a keyword list or a map.
  defp config_machine_opts(config) when is_list(config), do: Keyword.get(config, :machine_opts, [])
  defp config_machine_opts(%{machine_opts: opts}), do: opts
  defp config_machine_opts(_), do: []

  defp stop_machine(pid, child_id) do
    try do
      :gen_statem.stop(pid)
    catch
      :exit, _ -> :ok
    end

    wait_unregistered(child_id, 100)
  end

  defp wait_unregistered(_id, 0), do: :ok

  defp wait_unregistered(id, tries) do
    case Registry.lookup(SuperPi.Registry, {:conversation_machine, id}) do
      [] -> :ok
      _ -> Process.sleep(5) && wait_unregistered(id, tries - 1)
    end
  end

  # --- Child configuration ---

  # A child never has more permission than its parent.
  defp child_agent(role, parent_agent) do
    model_opts = if model = parent_agent["model"], do: [model: model], else: []
    workspace_opts = if paths = parent_agent["workspacePaths"], do: [workspace_paths: paths], else: []

    Harness.default().agent_defaults(model_opts ++ workspace_opts)
    |> Map.merge(Map.take(parent_agent, ["workspacePaths", "globalConfigDir", "appDataDir", "settingsOverride", "effort"]))
    |> Map.put("executionMode", child_mode(role, parent_agent))
    |> Map.put("dangerouslySkipPermissions", parent_agent["dangerouslySkipPermissions"] == true)
    |> Map.put("subagentDepth", Map.get(parent_agent, "subagentDepth", 0) + 1)
    |> Map.put("systemSections", [%{"id" => "core", "content" => Map.fetch!(@role_prompts, role)}])
    |> Map.put("tools", tools_for(role))
  end

  defp child_mode(role, parent_agent) when role in @read_only_roles do
    # `plan` is the strictest mode, so it never raises the parent's.
    _ = parent_agent
    "plan"
  end

  defp child_mode(_worker, parent_agent), do: Map.get(parent_agent, "executionMode", "accept-edits")

  defp tools_for(role) when role in @read_only_roles do
    Enum.filter(Tools.active_llm_tools(), &(&1["name"] in @read_only_tools))
  end

  defp tools_for(_worker) do
    Enum.reject(Tools.active_llm_tools(), &(&1["name"] in @never_in_child))
  end

  defp child_extensions do
    Enum.reject(Harness.default().extensions([]), fn ext ->
      mod = if is_tuple(ext), do: elem(ext, 0), else: ext
      mod in [__MODULE__, SuperPi.Plugins.Questionnaire, SuperPi.Plugins.Handoff]
    end)
  end

  defp max_depth, do: Application.get_env(:super_pi, :subagent_max_depth, 1)

  # --- Task records ---

  defp start_child_task(conversation_id, parent_task_id, role, prompt, child_id) do
    with {:ok, task} <-
           TaskEngine.create_task(
             conversation_id,
             "pi.subagent",
             %{"role" => role, "prompt" => prompt, "child_conversation_id" => child_id},
             owner_task_id: parent_task_id
           ),
         {:ok, running} <- TaskEngine.start_task(task.id) do
      running.id
    else
      _ -> nil
    end
  end

  defp finish_child_task(nil, _outcome), do: :ok
  defp finish_child_task(task_id, {:ok, text}), do: TaskEngine.complete_task(task_id, %{"summary" => truncate(text)}) && :ok
  defp finish_child_task(task_id, {:error, reason}), do: TaskEngine.fail_task(task_id, to_string(reason)) && :ok

  # --- Results ---

  defp final_text(%{"content" => blocks}) when is_list(blocks) do
    blocks |> Enum.map(&Map.get(&1, "text")) |> Enum.reject(&is_nil/1) |> Enum.join("\n") |> String.trim()
  end

  defp final_text(_), do: ""

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp truncate(text) when byte_size(text) > @max_summary_chars, do: binary_part(text, 0, @max_summary_chars) <> "\n[truncated]"
  defp truncate(text), do: text

  defp render(results) do
    failed? = Enum.any?(results, &(&1["status"] != "completed"))

    output =
      Enum.map_join(results, "\n\n", fn r ->
        case r["status"] do
          "completed" -> "Subagent (#{r["role"]}) finished:\n#{r["summary"]}"
          _ -> "Subagent (#{r["role"]}) failed: #{r["error"]}"
        end
      end)

    %{
      "output" => output,
      "structured_output" => %{"subagents" => results},
      "details" => %{"count" => length(results), "failed" => Enum.count(results, &(&1["status"] != "completed"))},
      "is_error" => failed? and Enum.all?(results, &(&1["status"] != "completed"))
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
