defmodule SuperPi.Workflow do
  @moduledoc "Compatibility API for callers of the former workflows. New harnesses compose Plugins.Profiles."
  alias SuperPi.Plugins.Profiles
  defdelegate supported?(agent), to: Profiles
  defdelegate available(agent), to: Profiles
  defdelegate select(agent, mode), to: Profiles

  def for_acp(agent),
    do: SuperPi.SessionModes.with_ceiling(agent, SuperPi.Plugins.Permissions.remote_mode("auto"))

  def check_tool(name, agent), do: SuperPi.Plugins.Permissions.tool_available(name, agent)
  defdelegate offered_tools(tools, agent), to: Profiles
  def permission(mode), do: %{"ask" => "plan", "plan" => "plan", "build" => "accept-edits"}[mode]
  def valid?(mode), do: permission(mode) != nil
end
