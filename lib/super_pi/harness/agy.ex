defmodule SuperPi.Harness.AGY do
  @moduledoc """
  Deprecated alias for `SuperPi.Harness.Workspace`.
  """

  @behaviour SuperPi.Harness

  @impl true
  def id, do: "super-pi-agy"

  @impl true
  def name, do: "Workspace Development Harness (Legacy Alias)"

  @impl true
  def description, do: "Legacy backward-compatible alias for Workspace Development Harness"

  @impl true
  def extensions(opts \\ []), do: SuperPi.Harness.Workspace.extensions(opts)

  @impl true
  def agent_defaults(opts \\ []), do: SuperPi.Harness.Workspace.agent_defaults(opts)
end
