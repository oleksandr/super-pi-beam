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
      "command": ["/home/oleksandr/Projects/super-pi-beam/bin/super-pi", "mcp"],
      "enabled": true
    }
  }
}
```

Verify connection:
```bash
opencode mcp list
# ✓ super-pi connected (/home/oleksandr/Projects/super-pi-beam/bin/super-pi mcp)
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

### Built-in Harnesses

- **`SuperPi.Harness.Default` (`super-pi-agent`)**:
  Clean, unopinionated autonomous coding agent with full workspace access (`read`, `write`, `edit`, `bash`, `grep`, `find`, `ls`, `tool_search`) and normative 10-rule context derivation.
- **`SuperPi.Harness.AGY` (`super-pi-agy`)**:
  Antigravity workflow harness. Dynamically loads the 5-tier customization extensions:
  - `Rules`: Hierarchical rule ingestion (`GEMINI.md`, `AGENTS.md`).
  - `Skills`: Modular skill discovery and progressive disclosure.
  - `HooksJson`: Lifecycle event triggers and pre-tool execution overrides.
  - `Permissions`: Workspace boundary and tool security policies.
  - `SlashCommands`: Client-facing interactive slash commands.
- **`SuperPi.Harness.Planner` (`super-pi-planner`)**:
  Read-only architectural planning specialist. Restricts tool exposure to read-only tools and enforces planning prompts.

### Listing Harnesses via CLI

```bash
bin/super-pi harness list
```

Output:
```text
Available Super-Pi Harnesses:
  * super-pi-agent    Super-Pi Autonomous Agent (Default) - Pure, unopinionated agent with standard tools and 10-rule context derivation
  * super-pi-agy      Super-Pi Antigravity Harness - Antigravity workflow harness loading Rules, Skills, Hooks, Permissions, and Slash Commands
  * super-pi-planner  Super-Pi Architecture Planner - Read-only architecture planner with restricted tool exposure
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
│   ├── agy/                       # Antigravity customization discovery & extensions
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
│   ├── harness/                   # Pluggable harness personas (Default, AGY, Planner)
│   ├── harness.ex                 # SuperPi.Harness behaviour contract & resolver
│   ├── mcp/
│   │   └── server.ex              # Model Context Protocol stdio server
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
