defmodule SuperPi.Harness.Planner do
  @moduledoc """
  Architecture planning harness with read-only tools and system verification prompts.
  """

  @behaviour SuperPi.Harness

  use SuperPi.Extension

  @read_only_tools ["read", "grep", "find", "ls", "tool_search"]

  @impl true
  def id, do: "super-pi-planner"

  @impl true
  def name, do: "Super-Pi Architecture Planner"

  @impl true
  def description do
    "Read-only architectural analysis, planning, and verification harness"
  end

  @impl true
  def extensions(_opts \\ []), do: [__MODULE__]

  @impl true
  def before_tool(tool_name, _args, _ctx) do
    if tool_name in @read_only_tools do
      :allow
    else
      {:block, "Tool '#{tool_name}' is not permitted in read-only Planner mode"}
    end
  end

  @impl true
  def agent_defaults(opts \\ []) do
    model = Keyword.get(opts, :model, "gemini-3-flash-preview")
    custom_sections = Keyword.get(opts, :system_sections, [])

    base_sections =
      if custom_sections != [] do
        custom_sections
      else
        [
          %{
            "id" => "planner_core",
            "content" =>
              "You are Super-Pi Architecture Planner. Inspect codebases, analyze requirements, and produce detailed architectural plans without modifying files."
          }
        ]
      end

    read_only_tools =
      SuperPi.Tools.active_llm_tools()
      |> Enum.filter(fn t -> t["name"] in ["read", "grep", "find", "ls", "tool_search"] end)

    %{
      "model" => model,
      "effort" => "high",
      "executionMode" => "plan",
      "workspacePaths" => [File.cwd!()],
      "tools" => read_only_tools,
      "systemSections" => base_sections
    }
  end
end
