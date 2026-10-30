defmodule SuperPi.Plugins.Skills do
  @moduledoc """
  Progressive Disclosure Skills Plugin (`SuperPi.Extension` behaviour).

  Implements progressive disclosure skill loading semantics:
  - Discovers skills across workspace, global (`<global config>/skills`), and custom skill locations.
  - Uses **progressive disclosure**: injects only `- <name> (<SKILL.md path>): <description>` into a
    dedicated `pi.system` section (`id: "skills_index"`) so the model's context window is not
    flooded with full skill bodies until the model reads `SKILL.md` on demand.
  """

  use SuperPi.Extension

  def id, do: "skills"
  def name, do: "Progressive Disclosure Skills Injector"

  def description,
    do: "Discovers workspace and global skills, indexing them via progressive disclosure"

  alias SuperPi.Discovery

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
          _ -> [%{"id" => "core", "content" => "You are an intelligent AI assistant."}]
        end

      clean_sections =
        Enum.reject(existing_sections, &(&1["id"] in ["skills_index", "agy_skills_index"]))

      updated_sections = clean_sections ++ [%{"id" => "skills_index", "content" => content}]

      {:ok, Map.put(agent_cfg, "systemSections", updated_sections)}
    end
  end
end
