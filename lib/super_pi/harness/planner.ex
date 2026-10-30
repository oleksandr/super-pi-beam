defmodule SuperPi.Harness.Planner do
  @moduledoc """
  Read-only planning harness (`super-pi-planner`).

  Callers select it by name because read-only is a safety boundary, so it stays a harness of its
  own. The boundary has three layers:

  1. The tool loadout is `read`, `grep`, `find`, `ls` and `tool_search`.
  2. `executionMode` is `plan` and `maxExecutionMode` is `plan`, so no flag can raise it.
  3. `Permissions` confines file tools to the workspace and applies the deny list, and
     `ProtectedPaths` hides `.env`, `.git/` and private keys from `read`.
  """

  alias SuperPi.Plugins

  use SuperPi.Harness,
    id: "super-pi-planner",
    name: "Super-Pi Planner",
    description: "Read-only architectural analysis, planning, and verification",
    effort: "high",
    mode: "plan",
    max_mode: "plan",
    workspace: :local,
    tools: {:only, ["read", "grep", "find", "ls", "tool_search"]},
    prompt:
      "You are Super-Pi Planner. Inspect codebases, analyze requirements, and produce detailed architectural plans without modifying files.",
    plugins: [Plugins.Permissions, Plugins.ProtectedPaths]
end
