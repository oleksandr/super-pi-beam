defmodule SuperPi.Harness.Assistant do
  @moduledoc """
  Assistant harness (`super-pi-assistant`): works with a human present and reaches the web.

  It targets a knowledge worker whose tools are third-party services, not a repository. The
  workspace kind is `none`: no file tools and no shell. What remains is artifacts, MCP tools
  (hosted connectors over HTTP, see `SuperPi.MCP.Client`) and `SuperPi.Plugins.Web`.

  - `Questionnaire`: asks the human a structured question.
  - `StructuredOutput`: ends a run with a machine-readable result.
  - `Handoff`, `Subagent`: context distillation and non-blocking delegation.
  - `Web`: `web_fetch`, and `web_search` when a search adapter is configured.
  - `CustomCompaction`: keeps a long chat alive.
  - `Todo`, `Permissions`, `TranscriptLogger`.

  `InlineBash` is not part of it. It runs `!{...}` outside the tool pipeline, so the workspace
  capability set cannot stop it, and a `none` workspace would still reach a shell.

  `executionMode` is `accept-edits`, the ceiling too. It replaces `super-pi-interactive`,
  `super-pi-agent` and `super-pi-fast` of earlier releases. All three ids stay resolvable as aliases.
  `super-pi-fast` no longer sets a low effort: use `--effort low`.
  """

  alias SuperPi.Plugins

  use SuperPi.Harness.DSL,
    id: "super-pi-assistant",
    name: "Super-Pi Assistant",
    description: "Assistant for knowledge work: questions, web access, MCP connectors and delegation, no filesystem",
    effort: "medium",
    mode: "accept-edits",
    max_mode: "accept-edits",
    workspace: %{"kind" => "none"},
    tools: :all,
    prompt:
      "You are Super-Pi Assistant. Work with the user: ask a structured question when a request is ambiguous, use the connected tools and the web to find facts, delegate long research to subagents, and end a task with a structured result when one is requested.",
    plugins: [
      Plugins.Questionnaire,
      Plugins.StructuredOutput,
      Plugins.Handoff,
      {Plugins.Subagent, timeout_ms: 30_000},
      {Plugins.Web, tools: [:fetch, :search]},
      Plugins.CustomCompaction,
      Plugins.Todo,
      Plugins.Permissions,
      Plugins.TranscriptLogger
    ]
end
