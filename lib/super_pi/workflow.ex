defmodule SuperPi.Workflow do
  @moduledoc "Compatibility API for callers of the former workflows. New harnesses compose Plugins.Profiles."
  alias SuperPi.Plugins.Profiles
  defdelegate supported?(agent), to: Profiles
  defdelegate available(agent), to: Profiles
  defdelegate select(agent, mode), to: Profiles
  defdelegate for_acp(agent), to: Profiles
  defdelegate check_tool(name, agent), to: Profiles
  defdelegate offered_tools(tools, agent), to: Profiles
  defdelegate permission(mode), to: SuperPi.ExecutionMode, as: :workflow_permission
  def valid?(mode), do: permission(mode) != nil
end
