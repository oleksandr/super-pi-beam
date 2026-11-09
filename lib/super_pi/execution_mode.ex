defmodule SuperPi.ExecutionMode do
  @moduledoc """
  Pure permission-mode normalization and workflow ceilings. Kept independent of tools,
  plugins and storage so durable configuration updates can enforce the same policy.
  """

  @ranks %{"plan" => 0, "accept-edits" => 1, "auto" => 2}

  def normalize(mode) when is_binary(mode) do
    mode = mode |> String.trim() |> String.downcase()
    if Map.has_key?(@ranks, mode), do: mode
  end

  def normalize(_), do: nil

  def rank_of(mode), do: Map.get(@ranks, normalize(mode), 0)

  def clamp(agent) do
    with ceiling when not is_nil(ceiling) <- normalize(agent["maxExecutionMode"]),
         mode when not is_nil(mode) <- normalize(agent["executionMode"]),
         true <- rank_of(mode) > rank_of(ceiling) do
      Map.put(agent, "executionMode", ceiling)
    else
      _ -> agent
    end
  end

  @doc "Enforces a plugin-independent tool policy and the harness ceiling."
  def enforce_policy(agent) do
    case get_in(agent, ["toolPolicy", "executionMode"]) do
      nil ->
        clamp(agent)

      ceiling ->
        mode = agent["executionMode"] || ceiling
        mode = if rank_of(mode) > rank_of(ceiling), do: ceiling, else: mode

        agent
        |> Map.put("executionMode", mode)
        |> Map.put("dangerouslySkipPermissions", false)
        |> clamp()
    end
  end
end
