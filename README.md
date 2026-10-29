# Super-Pi-BEAM

**Super-Pi-BEAM** is a durable, fault-tolerant general-purpose agent harness (with production coding presets) built on **Erlang/OTP 28** and **Elixir 1.20**. It reimplements the **Pi** and **Pi Durable** (`Chord v2`) architecture natively on the BEAM virtual machine.

---

## Key Capabilities

1. **Unified Always-Durable Engine (`SuperPi.Durable`)**:
   - Runs on **SQLite WAL mode** (`ecto_sqlite3`) by default for single-node CLI/TUI/RPC usage and switches to **PostgreSQL** (`postgrex`) at runtime (`SUPER_PI_DB_ADAPTER=postgres`) for multi-node clusters.
   - Persists 6 core tables (`conversations`, `entries`, `tasks`, `submissions`, `documents`, `document_revisions`) with a monotonic commit sequence (`seq`).
   - Maintains 5 built-in scoped conversation documents (`pi.agent`, `pi.provider`, `pi.live`, `pi.inbox`, `pi.usage`) with `Jsonpatch` operational deltas and `asOf` fork reconstruction.
   - Batches high-frequency streaming updates via `SuperPi.Durable.DeferredFlusher` (`100ms` `:ets` staging and `1000ms` lazy database flush).

2. **Two-Tier State Machines & Persistent Job Queues**:
   - **Active Turn Coordinator (`SuperPi.Conversation.Machine`)**: Erlang `:gen_statem` (`[:handle_event_function, :state_enter]`) managing `:recovering`, `:idle`, `:preparing_request`, `:streaming_llm`, `:executing_tools`, `:sleeping_backoff`, `:compacting`, and `:settling_run` with native `:postpone` queueing and mid-batch `:steer` preemption.
   - **Persisted Task Lifecycle (`SuperPi.Durable.TaskEngine`)**: `Fsmx` state transitions inside atomic `Ecto.Multi` transactions with `all_settled` and `fail_fast` child wait policies, `restart_limit: 5`, and bottom-up subtree abort.
   - **Background Queues (`Oban`)**: 4 queues (`:generation_retry`, `:compaction`, `:verification`, `:subagents`).

3. **Normative 10-Rule Context Derivation (`SuperPi.Durable.Context`)**:
   - Walks fork ancestry via `libgraph`, slices history at `head_entry_id` (`pi.compaction`, `pi.reset`), applies non-destructive `ContextEdit` (`omit`, `replace`), and appends positional `pi.system` prompt/tool deltas so LLM provider prompt caches remain warm.

4. **4-Layer Crash-Immune Tool Execution (`SuperPi.Env`)**:
   - **Layer 1**: Unlinked `Task.Supervisor.async_nolink` execution with `:max_heap_size` OOM kill boundaries (`SuperPi.Env.SandboxRunner`).
   - **Layer 2**: Streaming external OS process execution via `Exile` with automatic `4 MiB` spill-to-disk files.
   - **Layer 3**: Per-path advisory file locks (`SuperPi.Env.FileLock`) registered in `SuperPi.Registry` per `{env_id, canonical_path}` to serialize concurrent `write` and `edit` operations.
   - **Layer 4**: Built-in 3-channel tools (`read`, `write`, `edit`, `bash`, `grep`, `find`, `ls`, `tool_search`) returning `output`, `structured_output`, `details`, and `control` directives (`add_tools`, `handoff`, `terminate`), plus deterministic Codemode replay (`SuperPi.CodeMode.Journal`).

5. **Unified 12-Hook Extension Pipeline (`SuperPi.Extension`)**:
   - Supports `on_input`, `before_agent_start`, `before_compact`, `before_request`, `before_provider_request`, `after_response`, `before_tool`, `wrap_tool`, `after_tool`, `after_tools`, `on_yield`, and `after_run`.

6. **Day-1 `Owl` TUI & JSON-RPC 2.0 Server (`SuperPi.TUI.Owl`, `SuperPi.RPC.Server`)**:
   - Interactive ANSI terminal UI built on `Owl`.
   - JSON-RPC 2.0 server with `K = 2` ack-clocked backpressure (`session.watch` / `session.ack`) for external clients.

---

## Prerequisites & Setup

This repository uses [`mise`](https://mise.jdx.dev/) to pin **Erlang/OTP 28.4.2** and **Elixir 1.20.4-otp-28** (see `mise.toml` and `Makefile`).

```bash
# Compile the Elixir BEAM application and fetch dependencies
make build

# Run the full test suite (Elixir ExUnitProperties property tests + unit tests)
make test
```

---

## Recommended Harness Evaluation: OpenCode

**OpenCode** is the recommended interface for evaluating and testing the Super-Pi-BEAM harness. Super-Pi-BEAM natively integrates with OpenCode in two complementary modes:

### Mode 1: Upstream Model Provider (OpenAI-Compatible HTTP Gateway)
In this mode, OpenCode treats Super-Pi-BEAM as an upstream AI provider. When OpenCode submits a prompt, Super-Pi-BEAM runs its BEAM agent loop, executes workspace tools under OTP supervision, and streams back responses via Server-Sent Events (SSE):

1. **Start the Super-Pi Gateway**:
   ```bash
   # Standard logging (requests, session mapping, tool executions, completions):
   bin/super-pi gateway 4000

   # Verbose logging (streams live token deltas and thinking blocks to terminal):
   bin/super-pi gateway 4000 --verbose
   ```
2. **Configure OpenCode** (`~/.config/opencode/opencode.json`):
   ```json
   {
     "provider": {
       "super-pi": {
         "npm": "@ai-sdk/openai-compatible",
         "name": "Super-Pi BEAM",
         "options": {
           "baseURL": "http://127.0.0.1:4000/v1",
           "apiKey": "local-key"
         },
         "models": {
           "super-pi-agent": {
             "name": "Super-Pi Autonomous Agent",
             "limit": { "context": 128000, "output": 8192 }
           },
           "super-pi-agy": {
             "name": "Super-Pi Antigravity Harness",
             "limit": { "context": 128000, "output": 8192 }
           },
           "super-pi-planner": {
             "name": "Super-Pi Architecture Planner",
             "limit": { "context": 128000, "output": 8192 }
           },
           "super-pi-fast": {
             "name": "Super-Pi Fast Responder",
             "limit": { "context": 128000, "output": 8192 }
           }
         }
       }
     }
   }
   ```
3. **Verify Models & Run Queries**:
   ```bash
   # List available models
   opencode models super-pi

   # Run prompt through default Super-Pi agent
   opencode run "What is 15 plus 27?" --model super-pi/super-pi-agent

   # Run prompt through Antigravity harness (with skills, rules, and hooks)
   opencode run "Audit the codebase rules" --model super-pi/super-pi-agy
   ```
4. **Inspect Durable Chord v2 Sessions**:
   ```bash
   bin/super-pi session list
   bin/super-pi session show <ID>
   ```

### Mode 2: Native Model Context Protocol (MCP) Server
In this mode, OpenCode acts as the client and invokes Super-Pi-BEAM's 4-layer safe sandbox tools (`read`, `write`, `edit`, `bash`, `grep`, `find`, `ls`, `harness_task`) over standard I/O:

```json
{
  "mcp": {
    "super-pi": {
      "type": "local",
      "command": ["/path/to/super-pi-beam/bin/super-pi", "mcp"],
      "enabled": true
    }
  }
}
```

Verify connection:
```bash
opencode mcp list
# ✓ super-pi connected (/path/to/super-pi-beam/bin/super-pi mcp)
```

---

## Pluggable Harness Architecture (`SuperPi.Harness`)

Super-Pi-BEAM features a modular, pluggable harness system. Instead of hardcoding persona behaviors into the core engine or coupling them to specific UI clients, all personas implement the `@behaviour SuperPi.Harness` contract:

```elixir
defmodule SuperPi.Harness do
  @callback id() :: String.t()
  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback extensions(keyword()) :: list(module())
  @callback agent_defaults(keyword()) :: map()
end
```

### Built-in Harnesses & Declarative Showcase

- **`SuperPi.Harness.Default` (`super-pi-agent`)**:
  Clean, unopinionated autonomous coding agent with standard workspace tools and normative 10-rule context derivation.
- **`SuperPi.Harness.Autonomous` (`super-pi-auto`)**:
  Enterprise autonomous showcase declaratively assembled from safety, rollback, and cost-reduction plugins:
  `[ProtectedPaths, ConfirmDestructive, GitCheckpoint, AutoCommit, JevRouter, Todo, PromptCustomizer]`.
- **`SuperPi.Harness.Interactive` (`super-pi-interactive`)**:
  Human-collaborative interactive showcase declaratively assembled from:
  `[Questionnaire, InlineBash, StructuredOutput, Handoff, Subagent]`.
- **`SuperPi.Harness.AGY` (`super-pi-agy`)**:
  Antigravity workflow persona with 5-tier discovery (`Rules`, `Skills`, `HooksJson`, `Permissions`, `SlashCommands`).
- **`SuperPi.Harness.Planner` (`super-pi-planner`)**:
  Read-only architectural planning specialist with write protection.

### Listing Harnesses via CLI

```bash
bin/super-pi harness list
```

Output:
```text
HARNESS ID            NAME                                                  DESCRIPTION
--------------------------------------------------------------------------------------------------------------------------------------------------
super-pi-agent        Super-Pi Standard Agent                               Autonomous coding agent with 10-rule context derivation and safe sandbox
super-pi-auto         Super-Pi Autonomous Enterprise Harness                Composed of security shields, git rollbacks, Jev cascading, and task ledger
super-pi-interactive  Super-Pi Human-Collaborative Interactive Harness      Composed of clarification questionnaires, inline shell, terminating outputs, and handoff
super-pi-agy          Antigravity (AGY) Harness                             Antigravity persona with 5-tier skill discovery, rules, and hooks.json
super-pi-planner      Super-Pi Architecture Planner                         Read-only architectural analysis, planning, and verification harness
```

### General-Purpose Engine vs Coding Default

While Super-Pi-BEAM ships with software engineering defaults (`super-pi-agent`), the underlying OTP runtime is **strictly general-purpose**:
- **Universal Kernel**: State machines (`:gen_statem`), transactional persistence (`SQLite`/`Postgres`), crash-immune execution boundaries (`SuperPi.Env`), and streaming protocols run independently of domain logic.
- **Domain Decoupling**: An agent's domain is defined solely by its prompt guidelines and tool bindings inside a `SuperPi.Harness` module.
- **Non-Coding Persona Examples**:
  - **Document & Email Triage**: Ingests Himalaya CLI and Paperless-ngx REST tools for autonomous inbox zero and receipt archiving.
  - **Financial Intelligence**: Binds Actual Budget or banking APIs for transaction reconciliation, tag audits, and cash-flow reporting.
  - **Research & Synthesis**: Binds web search, HTTP scrapers, and PDF extractors with write/edit tools disabled.
  - **Support & Policy Guidance**: Binds FAQ and knowledge-base search with PII sanitization and sentiment escalation hooks.

### Declarative Plugins Ecosystem (`SuperPi.Plugins`)

Super-Pi-BEAM includes a library of **13 modular plugins** migrated from the Pi ecosystem and native BEAM patterns. Plugins implement the 12-hook `SuperPi.Extension` behaviour and can be assembled declaratively into any harness (even in separate external repositories):

| Plugin | Module | Impact / Feature |
| :--- | :--- | :--- |
| **`JevRouter`** | `SuperPi.Plugins.JevRouter` | **60–80% token cost reduction**: routes to reasoning model (`pro`) for planning, then cascades to fast model (`flash`) on first edit. |
| **`Handoff`** | `SuperPi.Plugins.Handoff` | **Resets active context to 0 tokens**: distills conversation decisions into a clean, focused child thread. |
| **`InlineBash`** | `SuperPi.Plugins.InlineBash` | **Saves 1 round-trip turn**: pre-evaluates `!{command}` expressions in user prompts directly on input. |
| **`StructuredOutput`** | `SuperPi.Plugins.StructuredOutput` | **Zero-waste completion**: provides terminating `structured_output` tool (`control: %{"terminate" => true}`). |
| **`Subagent`** | `SuperPi.Plugins.Subagent` | **Isolated context delegation**: spawns concurrent worker tasks under OTP supervision without polluting parent context. |
| **`Questionnaire`** | `SuperPi.Plugins.Questionnaire` | **Human-in-the-loop alignment**: structured multi-choice clarification tool with recommended defaults. |
| **`CustomCompaction`** | `SuperPi.Plugins.CustomCompaction` | **Tiered off-model summarization**: offloads compaction to fast models, preserving key decisions and tool cut-points. |
| **`Todo`** | `SuperPi.Plugins.Todo` | **Stateful task ledger**: manages task checklists stored in durable session documents (`pi.live`), surviving branch forks. |
| **`PromptCustomizer`** | `SuperPi.Plugins.PromptCustomizer` | **Adaptive guidance**: injects operational rules tailored specifically to active tools, keeping base prompts compact. |
| **`ProtectedPaths`** | `SuperPi.Plugins.ProtectedPaths` | **Safety shield**: blocks write/edit/read operations on `.env`, `.git/`, private keys, and credentials. |
| **`ConfirmDestructive`** | `SuperPi.Plugins.ConfirmDestructive` | **Execution gate**: intercepts dangerous bash operations (`rm -rf`, `DROP TABLE`, `git reset --hard`). |
| **`GitCheckpoint`** | `SuperPi.Plugins.GitCheckpoint` | **Atomic rollback**: takes git stash checkpoints before tool mutations to support clean fork recovery. |
| **`AutoCommit`** | `SuperPi.Plugins.AutoCommit` | **Turn finalization**: automatically stages and commits modified files when an agent run finishes. |

### First-Class Plugin Configuration Architecture

Plugins accept declarative configuration via `{PluginModule, opts}` or `{:alias, opts}` tuples. The `SuperPi.Extension` pipeline runner automatically unpacks these tuples and injects the options into `ctx[:config]` for all 12 extension lifecycle hooks (`run_on_input`, `run_before_agent_start`, `run_before_tool`, `run_after_run`, etc.).

```elixir
defmodule MyCompanyHarness do
  @behaviour SuperPi.Harness
  alias SuperPi.Plugins

  @declarative_plugins [
    # Guard against accidental secret leaks and credential reads
    {Plugins.ProtectedPaths, [tools: ["write", "edit", "read"]]},
    # Intercept destructive terminal operations
    {Plugins.ConfirmDestructive, [tools: ["bash"]]},
    # Dynamic model cascading: Pro reasoning for planning -> Flash for coding
    {Plugins.JevRouter, [planning_model: "gemini-3.1-pro-preview", implementation_model: "gemini-3-flash-preview"]},
    # Fast inline bash evaluations bounded by a 10s timeout
    {Plugins.InlineBash, [timeout_ms: 10_000, max_output_bytes: 8_192]},
    # Automatic turn finalization commit
    {Plugins.AutoCommit, [commit_prefix: "[my-agent]", enabled: true]}
  ]

  @impl true
  def extensions(opts \\ []) do
    extra = Keyword.get(opts, :extra_plugins, [])
    Plugins.resolve_all(@declarative_plugins ++ extra)
  end
end
```

### Configuration Matrix: Files vs Environment Variables vs Session State

To maintain clean separation of concerns, Super-Pi-BEAM enforces a 3-tier configuration hierarchy:

| Configuration Scope | Target Storage / Location | What Belongs Here |
| :--- | :--- | :--- |
| **Tier 1: Declarative Files** | `lib/super_pi/harness/*.ex` (or application codebase) | **Architectural Structure & Constraints**: Plugin pipeline assembly, tool definitions, static execution boundaries (`timeout_ms`, `max_output_bytes`), auto-commit prefixes, and default cascade models. Kept in version control. |
| **Tier 2: Environment Variables** | `.env` / Shell Environment | **Secrets & Infrastructure Adapters**: API tokens (`GEMINI_API_KEY`, `OPENAI_API_KEY`), database engine selection (`SUPER_PI_DB_ADAPTER=postgres`), port bindings (`SUPER_PI_GATEWAY_PORT`), fast operational overrides (`JEV_PLANNING_MODEL`, `JEV_IMPLEMENTATION_MODEL`), and host-specific path rules (`PROTECTED_PATHS`). Never committed. |
| **Tier 3: Durable Session State** | `pi.agent` document in SQLite / Postgres | **Dynamic Runtime Overrides**: Per-turn parameters passed by OpenCode, Gateway requests, or MCP callers (`model`, `temperature`, `thinking`, `effort`). Persisted durably across process crashes and branch forks. |

### Adding a Custom Harness

To add a new domain persona (e.g., security auditor, documentation bot, DevOps engineer):
1. Create `lib/super_pi/harness/my_persona.ex` implementing `@behaviour SuperPi.Harness`.
2. Register its identifier in `SuperPi.Harness.resolve/1` (or pass it via CLI/config).
3. The new persona is immediately accessible in OpenCode, the HTTP Gateway, the JSON-RPC server, and the CLI with zero core engine changes.

> [!NOTE]
> Client user interfaces (such as web UIs, IDE plugins, or previous Go Bubble Tea experiments) connect decoupled over HTTP Gateway, MCP, or JSON-RPC 2.0. The repository remains pure BEAM.

---

## Alternative Demos & Interactive Modes

### 1. Live Google Gemini Agentic Demo
Ensure `GEMINI_API_KEY` is exported in your environment, then run:

```bash
mise exec -- mix run examples/gemini_live_demo.exs
```

### 2. Interactive `Owl` Terminal UI
```bash
mise exec -- mix run examples/interactive_tui.exs
```
Supported slash commands inside the TUI:
- `/status` — Render the live ANSI status bar (conversation ID, model, state, token usage).
- `/context` — Inspect derived message count and active tools.
- `/compact` — Trigger manual context compaction.
- `/quit` — Exit the session.

### 3. External JSON-RPC 2.0 Showcase Client
Starts `SuperPi.RPC.Server` on a local TCP port and drives a full session (`session.open`, `session.watch` with `K = 2` backpressure, `session.ack`, `session.submit`):

```bash
mise exec -- mix run examples/rpc_showcase_client.exs
```

---

## Running the Property-Based Test Suite

Super-Pi-BEAM uses **`ExUnitProperties` (`StreamData`)** property-based testing across all core subsystems (`19` property suites, `14` unit/integration tests, and `1` doctest):

```bash
MIX_ENV=test mise exec -- mix test --trace
```

---

## Project Structure

```text
lib/
├── super_pi.ex
├── super_pi/
│   ├── ai/
│   │   ├── gemini_client.ex       # Live Google Gemini SSE streaming & tool-calling client
│   │   ├── stream_normalizer.ex   # Multi-provider SSE normalizer & partial JSON repair
│   │   └── virtual_model.ex       # Virtual model router & UUIDv7 session affinity
│   ├── code_mode/
│   │   └── journal.ex             # Deterministic Codemode crash-and-replay journal
│   ├── compaction.ex              # 4-mode context compaction & tool-pair cut-point finder
│   ├── conversation/
│   │   └── machine.ex             # :gen_statem turn coordinator & 12-hook execution
│   ├── durable/
│   │   ├── context.ex             # Normative 10-rule context derivation & pi.system diffs
│   │   ├── deferred_flusher.ex    # 100ms ETS / 1000ms DB deferred commit batcher
│   │   ├── doc.ex                 # Scoped JSON documents with Jsonpatch asOf rewind
│   │   ├── schemas/               # Ecto schemas (Conversation, Entry, Task, Submission, Document)
│   │   ├── storage.ex             # Atomic commit engine & fork manager
│   │   └── task_engine.ex         # Fsmx task scheduler, wait policies, & subtree abort
│   ├── env/
│   │   ├── behaviour.ex           # Execution environment contract
│   │   ├── file_lock.ex           # Per-path Registry-keyed advisory FileLock
│   │   ├── local.ex               # Local filesystem & gitignore-aware scanner
│   │   └── sandbox_runner.ex      # Unlinked Task supervisor with :max_heap_size & 4 MiB spill
│   ├── extension.ex               # Unified 12-hook extension behaviour & pipeline
│   ├── gateway/
│   │   └── router.ex              # OpenAI-compatible HTTP Gateway with SSE streaming
│   ├── harness/                   # Pluggable harness personas (Default, Autonomous, Interactive, AGY, Planner)
│   │   ├── agy/                   # Encapsulated AGY submodules (discovery, brain, CLI, extensions)
│   │   ├── agy.ex
│   │   ├── autonomous.ex          # Enterprise autonomous harness with Jev cascading & auto-commit
│   │   ├── default.ex             # Standard autonomous coding agent harness
│   │   ├── interactive.ex         # Human-in-the-loop interactive harness with questionnaires & handoffs
│   │   └── planner.ex             # Read-only architectural planning harness
│   ├── harness.ex                 # SuperPi.Harness behaviour contract & resolver
│   ├── mcp/
│   │   └── server.ex              # Model Context Protocol stdio server
│   ├── plugins/                   # 13 reusable Pi ecosystem plugins (JevRouter, Handoff, InlineBash, etc.)
│   ├── plugins.ex                 # SuperPi.Plugins registry, aliases, & option resolver
│   ├── repo.ex                    # Runtime-switchable SQLite3 / Postgrex Ecto repo facade
│   ├── rpc/
│   │   └── server.ex              # JSON-RPC 2.0 server with K=2 ack-clocked backpressure
│   ├── tools.ex                   # 7 built-in 3-channel tools & 5 ToolExposure modes
│   ├── tui/
│   │   └── owl.ex                 # Interactive Owl terminal UI
│   └── workers/
│       └── oban_workers.ex        # Oban workers (generation_retry, compaction, verification, subagents)
examples/
├── gemini_live_demo.exs           # Live Gemini 3 Flash tool-calling demo
├── interactive_tui.exs            # Interactive Owl TUI loop
└── rpc_showcase_client.exs        # External JSON-RPC 2.0 client showcase
test/                              # ExUnitProperties property-based & integration test suites
```
