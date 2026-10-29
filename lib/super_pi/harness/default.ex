defmodule SuperPi.Harness.Default do
  @moduledoc """
  Standard Super-Pi agent harness with 10-rule context derivation and safe tool sandbox.
  Unopinionated, minimal, and fast.
  """

  @behaviour SuperPi.Harness

  @impl true
  def id, do: "super-pi-agent"

  @impl true
  def name, do: "Super-Pi Standard Agent"

  @impl true
  def description do
    "Autonomous coding agent with 10-rule context derivation and 4-layer safe sandbox"
  end

  @impl true
  def extensions(_opts \\ []), do: []

  @impl true
  def agent_defaults(opts \\ []) do
    model = Keyword.get(opts, :model, "gemini-3-flash-preview")
    custom_sections = Keyword.get(opts, :system_sections, [])

    base_sections =
      if custom_sections != [] do
        custom_sections
      else
        [%{"id" => "core", "content" => "You are Super-Pi-BEAM, an autonomous durable AI agent."}]
      end

    %{
      "model" => model,
      "effort" => "medium",
      "executionMode" => "auto",
      "workspacePaths" => [File.cwd!()],
      "tools" => SuperPi.Tools.active_llm_tools(),
      "systemSections" => base_sections
    }
  end
end
