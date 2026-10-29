defmodule SuperPi.Harness.Interactive do
  @moduledoc """
  Human-Collaborative Interactive Harness (`super-pi-interactive`).

  Declaratively composed of clarification and distillation plugins:
  - `Questionnaire`: Human-in-the-loop clarification tool with recommended options.
  - `InlineBash`: Zero-turn prompt shell expansion (`!{cmd}`).
  - `StructuredOutput`: Terminating tool for emitting machine-readable results without extra turn cost.
  - `Handoff`: Context transfer to clean child sessions with zero token bloat.
  - `Subagent`: Delegated concurrent background tasks under OTP supervision.
  """

  @behaviour SuperPi.Harness
  alias SuperPi.Plugins

  @declarative_plugins [
    Plugins.Questionnaire,
    Plugins.InlineBash,
    Plugins.StructuredOutput,
    Plugins.Handoff,
    Plugins.Subagent
  ]

  @impl true
  def id, do: "super-pi-interactive"

  @impl true
  def name, do: "Super-Pi Human-Collaborative Interactive Harness"

  @impl true
  def description do
    "Interactive harness composed of clarification questionnaires, inline shell evaluation, terminating outputs, and context distillation"
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
            "id" => "interactive_core",
            "content" =>
              "You are Super-Pi Interactive Assistant. Cooperate closely with the user, ask structured questions when facing ambiguity, and emit terminating structured outputs when tasks finish."
          }
        ]
      end

    %{
      "model" => model,
      "effort" => "medium",
      "executionMode" => "interactive",
      "workspacePaths" => [File.cwd!()],
      "tools" => SuperPi.Tools.active_llm_tools(),
      "systemSections" => base_sections
    }
  end
end
