defmodule SuperPi.Harness.Fast do
  @moduledoc """
  High-throughput Fast Responder Harness (`super-pi-fast`).
  Optimized for low-latency, rapid turnarounds using `gemini-3-flash-preview`
  with lightweight toolsets and low reasoning effort.
  """

  @behaviour SuperPi.Harness

  @impl true
  def id, do: "super-pi-fast"

  @impl true
  def name, do: "Super-Pi Fast Responder"

  @impl true
  def description do
    "High-throughput fast response harness powered by gemini-3-flash-preview for rapid turnarounds"
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
        [%{"id" => "core", "content" => "You are Super-Pi-BEAM Fast Responder. Be concise, fast, and direct."}]
      end

    %{
      "model" => model,
      "effort" => "low",
      "executionMode" => "auto",
      "workspacePaths" => [File.cwd!()],
      "tools" => SuperPi.Tools.active_llm_tools(),
      "systemSections" => base_sections
    }
  end
end
