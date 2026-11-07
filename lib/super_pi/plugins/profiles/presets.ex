defmodule SuperPi.Plugins.Profiles.Presets do
  @moduledoc "Built-in profiles. Harnesses choose which presets to compose."

  def get(id) do
    case to_string(id) do
      "ask" ->
        %{
          "id" => "ask",
          "name" => "Ask",
          "description" => "Read-only repository questions and code review.",
          "execution_mode" => "plan",
          "tools" => "all",
          "prompt" => """
          You are in Ask. Answer questions about the repository, architecture, or supplied context.
          Inspect relevant files and read-only documentation and cite file paths in your answers.
          For code review, report prioritized actionable findings with supporting evidence.
          Do not produce an implementation plan unless requested. Do not edit files or run shell commands.
          """
        }

      "plan" ->
        %{
          "id" => "plan",
          "name" => "Plan",
          "description" => "Inspect, design, and propose a plan before implementation.",
          "execution_mode" => "plan",
          "tools" => "all",
          "prompt" => """
          You are in Plan. Inspect code and read-only documentation, compare designs and tradeoffs,
          and produce a concrete implementation plan with verification steps. Do not implement it.
          When ready to implement, call switch_mode with mode build and the proposed plan.
          Wait for the user's permission-dialog decision. Rejection or no client leaves you in Plan.
          """
        }

      "build" ->
        %{
          "id" => "build",
          "name" => "Build",
          "description" => "Implement and verify changes; unapproved commands ask first.",
          "execution_mode" => "accept-edits",
          "tools" => "all",
          "prompt" => """
          You are in Build. Implement the requested change using the agreed plan, verify it, and
          report results and limitations. Respect command approvals, workspace boundaries and deny rules.
          """
        }

      _ ->
        nil
    end
  end
end
