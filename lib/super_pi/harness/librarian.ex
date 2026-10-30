defmodule SuperPi.Harness.Librarian do
  @moduledoc """
  Librarian harness (`super-pi-librarian`): runs with no human present and remembers.

  It targets someone who points Super-Pi at a notes vault and walks away.

  - `Memory`: durable notes that outlive a conversation, with search and links.
  - `Scheduler`: scheduled and webhook-triggered runs.
  - `Web`: fetches pages to ingest.
  - `Rules`, `Skills`, `Todo`, `Permissions`, `ProtectedPaths`, `TranscriptLogger`.

  The loadout has no `bash`: a knowledge manager does not need a shell. The workspace roots come
  from `config :super_pi, :knowledge_paths`, else the usual workspace paths.

  `Memory` precedes any compaction plugin. `before_compact` stops at the first plugin that does not
  answer `:default`, and `Memory` must see the entries that compaction cuts.
  """

  alias SuperPi.Plugins

  use SuperPi.Harness.DSL,
    id: "super-pi-librarian",
    name: "Super-Pi Librarian",
    description: "Durable knowledge curation with scheduled capture, recall and web ingest",
    effort: "medium",
    mode: "accept-edits",
    max_mode: "accept-edits",
    workspace: :knowledge_paths,
    tools: {:except, ["bash"]},
    prompt:
      "You are Super-Pi Librarian. Capture, organize and recall a durable knowledge base. Search memory before you answer from your own knowledge, and write what is worth keeping.",
    plugins: [
      Plugins.Memory,
      Plugins.Scheduler,
      Plugins.Web,
      Plugins.Rules,
      Plugins.Skills,
      Plugins.Todo,
      Plugins.Permissions,
      Plugins.ProtectedPaths,
      Plugins.TranscriptLogger
    ]
end
