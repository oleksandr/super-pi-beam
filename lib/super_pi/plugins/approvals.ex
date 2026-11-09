defmodule SuperPi.Plugins.Approvals do
  @moduledoc "Explicit harness capabilities for command approvals, folder approvals and Git inspection."
  use SuperPi.Extension

  @impl true
  def lifecycle_effects, do: []

  def id, do: "approvals"
  def name, do: "Command and workspace approvals"
  def description, do: "Human approval requests and constrained Git inspection"

  @impl true
  def tools(agent) do
    if get_in(agent, ["workspace", "kind"]) in [nil, "local"] do
      specs = [
        Map.put(SuperPi.CommandApproval.spec(), "administrative", true),
        Map.put(SuperPi.GitInspection.spec(), "capabilities", ["exec"])
      ]

      if SuperPi.WorkspaceApproval.available?(agent),
        do: specs ++ [Map.put(SuperPi.WorkspaceApproval.spec(), "administrative", true)],
        else: specs
    else
      []
    end
  end

  @impl true
  def tool_policy("git_inspect", args, agent) do
    with {:ok, argv} <- SuperPi.GitInspection.argv(args) do
      {:ok,
       %{
         command: SuperPi.GitInspection.command(args),
         argv: argv,
         paths: [
           args["cd"] || args["dir"] || args["cwd"] || SuperPi.WorkspacePaths.primary(agent)
         ]
       }}
    end
  end

  def tool_policy("request_workspace_access", _args, agent) do
    if SuperPi.WorkspaceApproval.available?(agent),
      do: {:ok, %{}},
      else: {:error, "Workspace approval is available only in local CLI/ACP filesystem sessions."}
  end

  def tool_policy(_, _, _), do: {:ok, %{}}

  @impl true
  def execute_tool("request_command_approval", args, ctx),
    do: SuperPi.CommandApproval.request(args, ctx)

  def execute_tool("request_workspace_access", args, ctx),
    do: SuperPi.WorkspaceApproval.request(args, ctx)

  def execute_tool("git_inspect", args, ctx) do
    ws = ctx.workspace

    cd =
      SuperPi.WorkspacePaths.absolute(
        args["cd"] || args["dir"] || args["cwd"] || ".",
        ws.root || File.cwd!()
      )

    if ws.confined?, do: SuperPi.Env.Workspace.contain!(ws, cd)
    SuperPi.GitInspection.execute(args, ws.env, cd)
  end

  def execute_tool(_, _, _), do: :unhandled

  @impl true
  def prepare_request(agent, _ctx) do
    text =
      "Workspace roots (JSON): #{Jason.encode!(agent["workspacePaths"] || [])}. Relative paths use the first root. " <>
        "Use git_inspect for read-only Git queries. Use request_command_approval or request_workspace_access for user requests to approve commands or trust folders when available. Chat text alone does not change approvals."

    sections = Enum.reject(agent["systemSections"] || [], &(&1["id"] == "approvals"))

    {:ok,
     Map.put(agent, "systemSections", sections ++ [%{"id" => "approvals", "content" => text}])}
  end
end
