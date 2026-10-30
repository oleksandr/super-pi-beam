defmodule SuperPi.Harness.Workspace do
  @moduledoc """
  Unified Workspace Development Harness (`super-pi-workspace`).

  Declaratively composed of workspace integration and safety plugins:
  - `SlashCommands`: Interactive slash command expansion (`/plan`, `/goal`, `/boost`, `/model`, `/mode`).
  - `Rules`: Hierarchical repository and global agent rules injection with token budgeting.
  - `Skills`: 5-tier progressive disclosure skills discovery and indexing.
  - `Hooks`: Lifecycle hooks (`SessionStart`, `PreToolUse`, `PostToolUse`, `Stop`) from `hooks.json`.
  - `Permissions`: Workspace boundary confinement, command allowlists, and execution modes (`auto`, `plan`, `accept-edits`).
  - `TranscriptLogger`: Dual-write JSONL transcript logging (`transcript.jsonl` and `transcript_full.jsonl`).
  """

  @behaviour SuperPi.Harness
  alias SuperPi.Plugins

  @declarative_plugins [
    Plugins.SlashCommands,
    Plugins.Rules,
    Plugins.Skills,
    Plugins.Hooks,
    Plugins.Permissions,
    Plugins.TranscriptLogger
  ]

  @impl true
  def id, do: "super-pi-workspace"

  @impl true
  def name, do: "Workspace Development Harness"

  @impl true
  def description do
    "Workspace development persona with hierarchical rules, progressive skills, lifecycle hooks, permissions, and transcript logging"
  end

  @impl true
  def extensions(opts \\ []) do
    extra = Keyword.get(opts, :extra_plugins, [])
    Plugins.resolve_all(@declarative_plugins ++ extra)
  end

  @impl true
  def agent_defaults(opts \\ []) do
    model = Keyword.get(opts, :model, "gemini-3-flash-preview")
    effort = Keyword.get(opts, :effort, "medium")
    mode = Keyword.get(opts, :mode, "auto")
    workspace_paths = Keyword.get(opts, :workspace_paths, [File.cwd!()])
    custom_sections = Keyword.get(opts, :system_sections, [])

    base_sections =
      if custom_sections != [] do
        custom_sections
      else
        [%{"id" => "core", "content" => "You are an autonomous engineering assistant running in Super-Pi-BEAM workspace mode."}]
      end

    %{
      "model" => model,
      "effort" => effort,
      "executionMode" => mode,
      "workspacePaths" => workspace_paths,
      "tools" => SuperPi.Tools.active_llm_tools(),
      "systemSections" => base_sections
    }
  end
end
