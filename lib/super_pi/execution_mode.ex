defmodule SuperPi.ExecutionMode do
  @moduledoc """
  Pure permission-mode normalization and workflow ceilings. Kept independent of tools,
  plugins and storage so durable configuration updates can enforce the same policy.
  """

  @ranks %{"plan" => 0, "accept-edits" => 1, "auto" => 2}
  @workflow_permissions %{"ask" => "plan", "plan" => "plan", "build" => "accept-edits"}

  def normalize(mode) when is_binary(mode) do
    mode = mode |> String.trim() |> String.downcase()
    if Map.has_key?(@ranks, mode), do: mode
  end

  def normalize(_), do: nil

  def rank_of(mode), do: Map.get(@ranks, normalize(mode), 0)
  def workflow_permission(workflow), do: Map.get(@workflow_permissions, workflow)

  def clamp(agent) do
    with ceiling when not is_nil(ceiling) <- normalize(agent["maxExecutionMode"]),
         mode when not is_nil(mode) <- normalize(agent["executionMode"]),
         true <- rank_of(mode) > rank_of(ceiling) do
      Map.put(agent, "executionMode", ceiling)
    else
      _ -> agent
    end
  end

  # A workflow may tighten permissions; a legacy override cannot loosen its boundary.
  def enforce_workflow(%{"profilePolicy" => %{"execution_mode" => ceiling}} = agent) do
    mode = agent["executionMode"] || ceiling
    mode = if rank_of(mode) > rank_of(ceiling), do: ceiling, else: mode

    agent
    |> Map.put("executionMode", mode)
    |> Map.put("dangerouslySkipPermissions", false)
    |> clamp()
  end

  def enforce_workflow(agent) do
    case workflow_permission(agent["workflowMode"]) do
      nil ->
        agent

      ceiling ->
        mode = agent["executionMode"] || ceiling
        mode = if rank_of(mode) > rank_of(ceiling), do: ceiling, else: mode

        agent
        |> Map.put("executionMode", mode)
        |> Map.put("dangerouslySkipPermissions", false)
        |> clamp()
        |> tighten_workflow()
    end
  end

  defp tighten_workflow(%{"workflowMode" => "build", "executionMode" => mode} = agent) do
    if normalize(mode) == "plan", do: Map.put(agent, "workflowMode", "plan"), else: agent
  end

  defp tighten_workflow(agent), do: agent
end
