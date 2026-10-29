defmodule SuperPi.Plugins.StructuredOutput do
  @moduledoc """
  Structured Output Plugin (migrated from Pi ecosystem `structured-output.ts`).

  Registers the terminating `structured_output` tool, enabling agents to emit typed,
  machine-readable JSON outputs and finish turns immediately (`terminate: true`) without
  paying for an extra assistant response turn.
  """

  use SuperPi.Extension

  def id, do: "structured_output"
  def name, do: "Structured Output & Early Termination"
  def description, do: "Terminating tool for emitting typed machine-readable JSON without extra turn cost"

  @tool_spec %{
    "name" => "structured_output",
    "description" =>
      "Return a final structured answer. Use this as your last action when the user asks for structured output, JSON-like output, or a machine-readable summary. Terminate immediately upon calling.",
    "parameters" => %{
      "type" => "object",
      "properties" => %{
        "headline" => %{"type" => "string", "description" => "Concise headline or title for the result"},
        "summary" => %{"type" => "string", "description" => "One-paragraph summary of findings or actions taken"},
        "data" => %{"type" => "object", "description" => "Structured key-value payload"},
        "action_items" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "List of concrete next steps or bullet points"
        }
      },
      "required" => ["headline", "summary"]
    }
  }

  @impl true
  def before_agent_start(agent_cfg, _ctx) do
    existing_tools = Map.get(agent_cfg, "tools") || Map.get(agent_cfg, :tools) || []

    updated_tools =
      if Enum.any?(existing_tools, &(&1["name"] == "structured_output")) do
        existing_tools
      else
        existing_tools ++ [@tool_spec]
      end

    {:ok, Map.put(agent_cfg, "tools", updated_tools)}
  end

  @impl true
  def wrap_tool("structured_output", args, _next, _ctx) do
    headline = Map.get(args, "headline") || Map.get(args, :headline) || "Structured Result"
    summary = Map.get(args, "summary") || Map.get(args, :summary) || ""
    data = Map.get(args, "data") || Map.get(args, :data) || %{}
    action_items = Map.get(args, "action_items") || Map.get(args, :action_items) || []

    payload = %{
      "headline" => headline,
      "summary" => summary,
      "data" => data,
      "action_items" => action_items
    }

    %{
      "output" => "Saved structured output: #{headline}\nSummary: #{summary}",
      "structured_output" => payload,
      "details" => payload,
      "control" => %{"terminate" => true}
    }
  end

  def wrap_tool(_name, args, next, _ctx) do
    next.(args)
  end

  @doc """
  Returns the tool specification map for direct registration.
  """
  def tool_spec, do: @tool_spec
end
