defmodule SuperPi.Plugins.PromptCustomizer do
  @moduledoc """
  Prompt Customizer Plugin (migrated from Pi ecosystem `prompt-customizer.ts`).

  Dynamically injects context-aware operational guidelines into `systemSections`
  tailored specifically to the active tools and capabilities exposed in the current turn.
  Avoids bloating the base system prompt with unused rules.
  """

  use SuperPi.Extension

  def id, do: "prompt_customizer"
  def name, do: "Adaptive Tool Guidance & Prompt Customizer"
  def description, do: "Injects modular operational rules dynamically based on active tools"

  @impl true
  def before_agent_start(agent_cfg, _ctx) do
    tools = Map.get(agent_cfg, "tools", [])
    tool_names = Enum.map(tools, &Map.get(&1, "name")) |> MapSet.new()

    sections = Map.get(agent_cfg, "systemSections", [])

    guidance_content = build_guidance(tool_names)

    updated_sections =
      if byte_size(guidance_content) > 0 do
        # Replace or append tool_guidance section
        filtered = Enum.reject(sections, &(&1["id"] == "tool_guidance"))
        filtered ++ [%{"id" => "tool_guidance", "content" => guidance_content}]
      else
        sections
      end

    {:ok, Map.put(agent_cfg, "systemSections", updated_sections)}
  end

  defp build_guidance(tool_names) do
    rules = []

    rules =
      if MapSet.member?(tool_names, "read") do
        rules ++ ["- `read`: Use for file contents and images. Use offset and limit for files over 2,000 lines."]
      else
        rules
      end

    rules =
      if MapSet.member?(tool_names, "edit") do
        rules ++ ["- `edit`: Replace exact unique substrings. Include surrounding context if target appears multiple times."]
      else
        rules
      end

    rules =
      if MapSet.member?(tool_names, "write") do
        rules ++ ["- `write`: Create new files or overwrite existing files completely. Create parent directories automatically."]
      else
        rules
      end

    rules =
      if MapSet.member?(tool_names, "bash") do
        rules ++ ["- `bash`: Run non-interactive commands. Check exits, handle errors, and prefer targeted file tools over shell loops."]
      else
        rules
      end

    rules =
      if MapSet.member?(tool_names, "structured_output") do
        rules ++ ["- `structured_output`: Emit final machine-readable results and terminate immediately without additional conversational turns."]
      else
        rules
      end

    rules =
      if MapSet.member?(tool_names, "ask_question") do
        rules ++ ["- `ask_question`: When facing ambiguous requirements or design forks, ask clarification questions before acting."]
      else
        rules
      end

    if rules != [] do
      "### Active Tool Operational Guidelines\n" <> Enum.join(rules, "\n")
    else
      ""
    end
  end
end
