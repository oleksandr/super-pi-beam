defmodule SuperPi.Harness.AGY do
  @moduledoc """
  Antigravity (AGY) customization harness.
  Plugs in 5-tier skill discovery, AGENTS.md rules enforcement, hooks.json, permissions, and slash commands.
  """

  @behaviour SuperPi.Harness

  @impl true
  def id, do: "super-pi-agy"

  @impl true
  def name, do: "Antigravity (AGY) Harness"

  @impl true
  def description do
    "Antigravity customization persona with 5-tier skill discovery, rules, and hooks.json"
  end

  @impl true
  def extensions(_opts \\ []) do
    SuperPi.Harness.AGY.CLI.default_extensions()
  end

  @impl true
  def agent_defaults(opts \\ []) do
    model = Keyword.get(opts, :model, "gemini-3-flash-preview")
    custom_sections = Keyword.get(opts, :system_sections, [])

    base_sections =
      if custom_sections != [] do
        custom_sections
      else
        [%{"id" => "core", "content" => "You are Super-Pi-BEAM running in Antigravity (AGY) harness mode."}]
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
