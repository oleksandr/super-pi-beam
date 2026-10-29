defmodule SuperPi.Harness.AGY.Extensions.Skills do
  @moduledoc """
  Antigravity Progressive Disclosure Skills Extension (`SuperPi.Extension` behaviour).

  Implements exact `agy` skill loading semantics (`docs/skills.md`):
  - Discovers skills across the 5 priority tiers (`Workspace`, `Workspace skills.json`, `Global ~/.gemini/config/skills`,
    `Built-in ~/.gemini/antigravity-cli/builtin/skills`, and `Global skills.json`).
  - Uses **progressive disclosure**: injects only `- <name> (<SKILL.md path>): <description>` into a
    dedicated `pi.system` section (`id: "agy_skills_index"`) so the model's context window is not
    flooded with full skill bodies until the model reads `SKILL.md` on demand.
  """

  use SuperPi.Extension

  alias SuperPi.Harness.AGY.Discovery

  @impl true
  def before_agent_start(agent_cfg, _ctx) do
    workspace_dirs = Map.get(agent_cfg, "workspacePaths", [File.cwd!()])
    global_dir = Map.get(agent_cfg, "globalConfigDir", Discovery.default_global_config_dir())
    app_data_dir = Map.get(agent_cfg, "appDataDir", Discovery.default_app_data_dir())

    skills =
      Discovery.discover_skills(workspace_dirs,
        global_config_dir: global_dir,
        app_data_dir: app_data_dir
      )

    if skills == [] do
      {:ok, agent_cfg}
    else
      lines =
        Enum.map(skills, fn s ->
          "- #{s.name} (#{s.path}): #{s.description}"
        end)

      content =
        "Available skills (read SKILL.md before proceeding when relevant):\n" <>
          Enum.join(lines, "\n")

      existing_sections =
        case Map.get(agent_cfg, "systemSections") do
          list when is_list(list) -> list
          _ -> [%{"id" => "core", "content" => "You are Antigravity (SuperPi.Harness.AGY)."}]
        end

      updated_sections =
        upsert_section(existing_sections, %{
          "id" => "agy_skills_index",
          "content" => content
        })

      {:ok, Map.put(agent_cfg, "systemSections", updated_sections)}
    end
  end

  defp upsert_section(sections, %{"id" => target_id} = new_sec) do
    if Enum.any?(sections, &(&1["id"] == target_id)) do
      Enum.map(sections, fn s -> if s["id"] == target_id, do: new_sec, else: s end)
    else
      sections ++ [new_sec]
    end
  end
end
