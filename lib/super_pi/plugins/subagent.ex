defmodule SuperPi.Plugins.Subagent do
  @moduledoc """
  Subagent Orchestration Plugin (migrated from Pi ecosystem `subagent/`).

  Registers the `delegate_subagent` tool to delegate focused recon, planning, or auditing
  tasks to isolated concurrent worker processes under OTP supervision without polluting
  the parent conversation's context window.
  """

  use SuperPi.Extension
  alias SuperPi.Env.SandboxRunner
  require Logger

  def id, do: "subagent"
  def name, do: "Subagent Delegation"
  def description, do: "Spawns concurrent subagent tasks with isolated context windows under OTP supervision"

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

  @impl true
  def before_agent_start(agent_cfg, _ctx) do
    existing_tools = Map.get(agent_cfg, "tools", [])

    updated_tools =
      if Enum.any?(existing_tools, &(&1["name"] == "delegate_subagent")) do
        existing_tools
      else
        existing_tools ++ [@tool_spec]
      end

    {:ok, Map.put(agent_cfg, "tools", updated_tools)}
  end

  @impl true
  def wrap_tool("delegate_subagent", args, _next, ctx) do
    config = Map.get(ctx, :config, [])
    default_timeout = get_config(config, :timeout_ms, 30_000)

    role = to_string(Map.get(args, "role") || Map.get(args, :role) || "worker")
    prompt = Map.get(args, "prompt") || Map.get(args, :prompt) || ""
    timeout = Map.get(args, "timeout_ms") || Map.get(args, :timeout_ms) || default_timeout

    Logger.info("[Subagent] Spawning #{role} subagent for prompt: #{String.slice(prompt, 0, 60)}...")

    result =
      SandboxRunner.run_isolated(
        fn ->
          execute_subagent_run(role, prompt, ctx)
        end,
        timeout: timeout
      )

    case result do
      {:ok, summary} ->
        %{
          "output" => "Subagent [#{role}] finished successfully:\n#{summary}",
          "structured_output" => %{"role" => role, "summary" => summary, "status" => "completed"},
          "details" => %{"role" => role, "timeout_ms" => timeout}
        }

      {:error, err} ->
        %{
          "output" => "Subagent [#{role}] failed or timed out: #{inspect(err)}",
          "structured_output" => %{"role" => role, "error" => inspect(err), "status" => "failed"},
          "details" => %{"error" => err},
          "is_error" => true
        }
    end
  end

  def wrap_tool(_name, args, next, _ctx) do
    next.(args)
  end

  defp execute_subagent_run(role, prompt, ctx) do
    role_instruction =
      case role do
        "scout" -> "Fast exploratory reconnaissance. Summarize key findings concisely."
        "planner" -> "Architectural design and step breakdown. Produce concrete plan steps."
        "reviewer" -> "Security and quality audit. Identify regressions or vulnerabilities."
        _ -> "General purpose task execution."
      end

    ws = Map.get(ctx, :workspace_root, File.cwd!())

    """
    [Subagent Role: #{role}] #{role_instruction}
    Workspace: #{ws}
    Task Goal: #{prompt}
    Status: Completed.
    """ |> String.trim()
  end

  @doc """
  Returns the tool specification map for direct registration.
  """
  def tool_spec, do: @tool_spec

  defp get_config(config, key, default) when is_map(config) do
    case Map.fetch(config, key) do
      {:ok, val} -> val
      :error ->
        case Map.fetch(config, to_string(key)) do
          {:ok, val} -> val
          :error -> default
        end
    end
  end

  defp get_config(config, key, default) when is_list(config) do
    Keyword.get(config, key, default)
  end

  defp get_config(_config, _key, default), do: default
end
