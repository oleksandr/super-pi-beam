defmodule SuperPi.Harness.Autonomous do
  @moduledoc """
  Autonomous Enterprise Harness (`super-pi-auto`).

  Declaratively composed of production safety and efficiency plugins with concrete configurations:
  - `ProtectedPaths`: Blocks access to sensitive configuration and credentials.
  - `ConfirmDestructive`: Safety gate for catastrophic commands (`rm -rf`, `DROP TABLE`).
  - `GitCheckpoint`: Stash checkpoints before tool modifications.
  - `AutoCommit`: Clean atomic commit upon turn settlement with `[super-pi-auto]` prefix.
  - `JevRouter`: Dynamic model cascading (pro planning -> flash implementation).
  - `Todo`: Durable task ledger persisted across turns and forks.
  - `PromptCustomizer`: Adaptive tool operational guidance.
  """

  @behaviour SuperPi.Harness
  alias SuperPi.Plugins

  @declarative_plugins [
    {Plugins.ProtectedPaths, [tools: ["write", "edit", "read"]]},
    {Plugins.ConfirmDestructive, [tools: ["bash"]]},
    Plugins.GitCheckpoint,
    {Plugins.AutoCommit, [commit_prefix: "[super-pi-auto]", enabled: true]},
    {Plugins.JevRouter, [planning_model: "gemini-3.1-pro-preview", implementation_model: "gemini-2.5-flash"]},
    Plugins.Todo,
    Plugins.PromptCustomizer
  ]

  @impl true
  def id, do: "super-pi-auto"

  @impl true
  def name, do: "Super-Pi Autonomous Enterprise Harness"

  @impl true
  def description do
    "Autonomous harness composed of security shields, git rollbacks, dynamic model cascading, and task ledger"
  end

  @impl true
  def extensions(opts \\ []) do
    extra = Keyword.get(opts, :extra_plugins, [])
    Plugins.resolve_all(@declarative_plugins ++ extra)
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
            "id" => "auto_core",
            "content" =>
              "You are Super-Pi Autonomous Agent. Execute tasks with rigorous self-verification, safe tooling, and stateful task ledger tracking."
          }
        ]
      end

    %{
      "model" => model,
      "effort" => "high",
      "executionMode" => "auto",
      "workspacePaths" => [File.cwd!()],
      "tools" => SuperPi.Tools.active_llm_tools(),
      "systemSections" => base_sections
    }
  end
end
