defmodule SuperPi.Plugins.Approvals do
  @moduledoc "Explicit harness capabilities for command approvals, folder approvals and Git inspection."
  use SuperPi.Extension

  def id, do: "approvals"
  def name, do: "Command and workspace approvals"
  def description, do: "Human approval requests and constrained Git inspection"

  @impl true
  def before_agent_start(agent, _ctx) do
    added = [SuperPi.CommandApproval.spec(), SuperPi.GitInspection.spec()]

    added =
      if SuperPi.WorkspaceApproval.available?(agent),
        do: added ++ [SuperPi.WorkspaceApproval.spec()],
        else: added

    names = Enum.map(added, & &1["name"])

    {:ok,
     Map.update(
       agent,
       "tools",
       added,
       &(Enum.reject(&1, fn t -> t["name"] in names end) ++ added)
     )}
  end
end
