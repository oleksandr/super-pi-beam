defmodule SuperPi.Plugins.Subagent do
  @moduledoc """
  Subagent Orchestration Plugin (migrated from Pi ecosystem `subagent/`).

  Not implemented. The plugin does not advertise `delegate_subagent`, and a call to it returns
  a `not_implemented` error. A real subagent needs a child conversation that runs its own
  model loop (Task 35 on the project board).
  """

  use SuperPi.Extension
  alias SuperPi.Tools
  require Logger

  def id, do: "subagent"
  def name, do: "Subagent Delegation"
  def description, do: "Subagent delegation (not implemented: calls return a not_implemented error)"

  @tool_spec %{
    "name" => "delegate_subagent",
    "description" =>
      "Delegate a focused task (recon, research, code review, or sub-task planning) to an isolated subagent. The subagent executes concurrently with a dedicated context window and returns a concise summary.",
    "parameters" => %{
      "type" => "object",
      "properties" => %{
        "role" => %{
          "type" => "string",
          "enum" => ["scout", "planner", "reviewer", "researcher", "worker"],
          "description" => "Persona/role of the delegated subagent"
        },
        "prompt" => %{"type" => "string", "description" => "Detailed task description for the subagent"},
        "timeout_ms" => %{"type" => "integer", "description" => "Max runtime timeout in milliseconds (default: 30000)"}
      },
      "required" => ["role", "prompt"]
    }
  }

  # The tool is not advertised: it has no implementation, so the model must not be offered it.
  # Register `tool_spec/0` here again when a child conversation can run a real model loop.
  @impl true
  def before_agent_start(agent_cfg, _ctx), do: {:ok, agent_cfg}

  @impl true
  def wrap_tool("delegate_subagent", _args, _next, _ctx) do
    Logger.warning("[Subagent] delegate_subagent called but subagents are not implemented")
    Tools.not_implemented_result("delegate_subagent")
  end

  def wrap_tool(_name, args, next, _ctx) do
    next.(args)
  end

  @doc """
  Returns the tool specification map for direct registration.
  """
  def tool_spec, do: @tool_spec
end
