defmodule SuperPi.Harness.Code do
  @moduledoc """
  Coding harness (`super-pi-code`): mutates a repository, reversibly.

  - `Permissions`, `ProtectedPaths`, `ConfirmDestructive`: the safety floor (execution modes,
    workspace boundary, secrets, destructive shell commands).
  - `GitCheckpoint`, `AutoCommit`: stash checkpoints before edits and an atomic commit when a turn
    settles. `AutoCommit` is off. Turn it on with `{Plugins.AutoCommit, enabled: true}` in
    `extra_plugins` or a harness of your own.
  - `Rules`, `Skills`, `Hooks`, `SlashCommands`: repository-native customization.
  - `JevRouter`: model cascading. Planning and implementation models come from
    `config :super_pi, :planning_model` and `:implementation_model`.
  - `Todo`, `PromptCustomizer`, `TranscriptLogger`.

  It replaces `super-pi-workspace`, `super-pi-auto`, `super-pi-agent` and `super-pi-fast` of earlier
  releases, which stay resolvable as aliases (`super-pi-agent` and `-fast` now map to
  `super-pi-assistant`; use `--effort low` for the old fast profile).
  """

  alias SuperPi.Harness.Defaults
  alias SuperPi.Plugins

  use SuperPi.Harness,
    id: "super-pi-code",
    name: "Super-Pi Code",
    description: "Repository coding agent: reversible edits, rules, skills, hooks, model cascading",
    effort: "high",
    mode: "accept-edits",
    max_mode: "auto",
    workspace: :local,
    tools: :all,
    prompt:
      "You are Super-Pi Code, an autonomous engineering agent. Make changes in small steps, verify them, and keep the repository in a state that can be rolled back.",
    plugins: [
      Plugins.SlashCommands,
      Plugins.Rules,
      Plugins.Skills,
      Plugins.Hooks,
      Plugins.Permissions,
      Plugins.ProtectedPaths,
      {Plugins.ConfirmDestructive, tools: ["bash", "sh", "terminal", "run_command", "exec"]},
      Plugins.GitCheckpoint,
      {Plugins.AutoCommit, commit_prefix: "[super-pi]", enabled: false},
      {Plugins.JevRouter, Defaults.model_route()},
      Plugins.Todo,
      Plugins.PromptCustomizer,
      Plugins.TranscriptLogger
    ]
end
