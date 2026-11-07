defmodule SuperPi.Workflow do
  @moduledoc """
  Coding workflows, independent of permission modes. The stored tool loadout stays intact;
  instructions and offered tools are derived for each request, so switching back to Build
  restores the harness without losing tools discovered during the conversation.
  """

  alias SuperPi.Plugins
  alias SuperPi.Plugins.Permissions
  alias SuperPi.Tools

  @modes [
    %{
      "id" => "ask",
      "name" => "Ask",
      "description" =>
        "Discuss supplied context or request command/folder approvals. No repository discovery."
    },
    %{
      "id" => "plan",
      "name" => "Plan",
      "description" => "Inspect code, compare designs, and review changes. Read-only."
    },
    %{
      "id" => "build",
      "name" => "Build",
      "description" => "Edit and verify code. Commands outside the allow list ask first."
    }
  ]
  @hook_sections ["session_start_hooks", "agy_session_start_hooks"]

  @prompts %{
    "ask" => """
    You are in Ask workflow. Answer questions using only this conversation and context explicitly
    supplied by the user. You cannot inspect the repository, fetch documentation,
    run commands, or make changes. If the supplied context is insufficient, say what is missing
    and ask the user to provide it or select Plan for repository inspection. Do not claim to have
    inspected, tested, or changed anything. Prior tool results in this conversation may be used.
    The tool exceptions are request_command_approval and request_workspace_access: when the user
    asks to approve commands or trust a folder, use the corresponding permission dialog.
    They change permissions only after a user decision and never run commands or inspect files.
    Approved commands and folders still cannot be used in Ask.
    """,
    "plan" => """
    You are in Plan workflow. Inspect the available code and read-only documentation to understand
    the task. For architecture work, compare viable designs, explain tradeoffs, and recommend an
    approach. Ask clarifying questions in the conversation when needed. For code review, report
    prioritized actionable findings with file references and supporting evidence; do not force
    review findings into an implementation plan. You cannot edit files, run shell commands, or change
    external state. Use git_inspect for read-only Git status, log and diff; command approvals apply.
    Use request_command_approval when the user asks to allow command prefixes. The permission dialog
    offers conversation-only approval or saving for future sessions. Never claim a chat message
    itself changed the allow list. Do not implement a proposal until the user selects Build. State verification
    limits when tests or commands would be needed.
    When the user asks to trust or add a folder, use request_workspace_access if available.
    Folder approval grants read access in Plan; it does not permit editing or shell execution.
    """,
    "build" => """
    You are in Build workflow. Implement the user's requested change, using agreed design choices
    from this conversation. Make focused edits, run appropriate verification, and report the result
    and any remaining limitations. File edits are permitted; shell commands outside the allow list
    require user approval. Respect workspace boundaries and permission decisions.
    When the user asks to allow command prefixes, call request_command_approval. Its permission
    dialog offers conversation-only approval or saving for future sessions. Chat text alone does
    not change the policy. Use narrow prefixes, such as ["git", "diff"], and never edit rule files
    yourself to bypass the approval dialog.
    An && chain needs approval for every command in it. Existing command prefixes and command(...)
    rules can cover its commands together; an already covered chain needs no new approval.
    When the user asks to trust or add a folder, call request_workspace_access if available.
    Folder approvals are separate from command approvals and require a permission-dialog decision.
    """
  }

  def supported?(agent),
    do: agent["harness"] in ["super-pi-code", "super-pi-workspace", "super-pi-auto"]

  def valid?(mode), do: permission(mode) != nil
  defdelegate permission(mode), to: SuperPi.ExecutionMode, as: :workflow_permission

  def available(agent) do
    ceiling = Permissions.rank_of(agent["maxExecutionMode"] || "auto")
    Enum.filter(@modes, &(Permissions.rank_of(permission(&1["id"])) <= ceiling))
  end

  def select(agent, mode) do
    cond do
      not supported?(agent) ->
        {:error, "Workflows are available only for the code harness."}

      not valid?(mode) ->
        {:error, "Unknown workflow #{inspect(mode)}. Choose ask, plan, or build."}

      not Enum.any?(available(agent), &(&1["id"] == mode)) ->
        {:error, "Workflow #{mode} exceeds this session's permission ceiling."}

      true ->
        {:ok,
         Map.merge(agent, %{
           "workflowMode" => mode,
           "executionMode" => permission(mode),
           "dangerouslySkipPermissions" => false
         })}
    end
  end

  # ACP sessions retain the remote ceiling for slash commands as well as the mode picker.
  def for_acp(agent) do
    if supported?(agent) do
      remote = Permissions.remote_mode("auto")
      ceiling = agent["maxExecutionMode"] || "auto"

      ceiling =
        if Permissions.rank_of(remote) < Permissions.rank_of(ceiling), do: remote, else: ceiling

      agent = Map.put(agent, "maxExecutionMode", ceiling)

      mode =
        agent["workflowMode"] || if(agent["executionMode"] == "plan", do: "plan", else: "build")

      case select(agent, mode) do
        {:ok, updated} -> updated
        {:error, _} -> select(agent, "plan") |> elem(1)
      end
    else
      agent
    end
  end

  def check_tool("request_command_approval", _agent), do: :allow
  def check_tool("request_workspace_access", _agent), do: :allow

  def check_tool(name, agent) do
    case agent["workflowMode"] do
      "ask" ->
        {:block, "Tools are unavailable in Ask. Select Plan to inspect the repository."}

      "plan" ->
        if read_only?(name, agent),
          do: :allow,
          else: {:block, "Tool `#{name}` is blocked in Plan (read-only workflow)."}

      _ ->
        :allow
    end
  end

  def offered_tools(tools, agent) do
    Enum.filter(tools, &(check_tool(&1["name"], agent) == :allow))
  end

  def sections(sections, agent) do
    case Map.fetch(@prompts, agent["workflowMode"]) do
      {:ok, content} ->
        base = if agent["workflowMode"] == "ask", do: [], else: sections

        removed =
          if agent["workflowMode"] == "plan",
            do: ["workflow" | @hook_sections],
            else: ["workflow"]

        base = Enum.reject(base, &(&1["id"] in removed))
        base ++ [%{"id" => "workflow", "content" => content <> workspace_context(agent)}]

      :error ->
        sections
    end
  end

  defp workspace_context(%{"workflowMode" => "ask"}), do: ""

  defp workspace_context(agent) do
    roots = agent["workspacePaths"] || []

    "\nWorkspace roots (JSON): #{Jason.encode!(roots)}. " <>
      "Relative paths and commands default to the first root. Use absolute paths or an explicit " <>
      "command working directory to target another root."
  end

  # Lifecycle hooks and auto-commit can execute outside the permission tool pipeline.
  # Only the listed passive extensions participate in Ask and Plan.
  def extensions(extensions, agent) do
    allowed =
      case agent["workflowMode"] do
        "ask" -> ask_extensions()
        "plan" -> plan_extensions()
        _ -> nil
      end

    if allowed do
      Enum.filter(extensions, fn
        {mod, _} -> mod in allowed
        mod -> mod in allowed
      end)
    else
      extensions
    end
  end

  # Keep module references at runtime to avoid compile dependencies on plugins.
  defp ask_extensions, do: [Plugins.SlashCommands, Plugins.Permissions, Plugins.TranscriptLogger]

  defp plan_extensions do
    ask_extensions() ++
      [
        Plugins.Rules,
        Plugins.Skills,
        Plugins.ProtectedPaths,
        Plugins.JevRouter,
        Plugins.PromptCustomizer
      ]
  end

  defp read_only?(name, agent) do
    case Tools.effects(name, agent) do
      [_ | _] = effects -> Enum.all?(effects, &(&1 in ["read", "net_read"]))
      _ -> false
    end
  end
end
