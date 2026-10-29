# Super-Pi-BEAM

**Super-Pi-BEAM** is a durable, fault-tolerant coding agent harness built on **Erlang/OTP 28** and **Elixir 1.20**. It reimplements the **Pi** and **Pi Durable** (`Chord v2`) architecture natively on the BEAM virtual machine.

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

This polyglot monorepo uses [`mise`](https://mise.jdx.dev/) to pin **Erlang/OTP 28.4.2**, **Elixir 1.20.4-otp-28**, **Rust 1.99.1**, and **Go 1.27.2** (see `mise.toml` and `Makefile`).

```bash
# Build both the Elixir BEAM harness and the Go Bubble Tea TUI (bin/agy-tui)
make build

# Run the full polyglot test suite (Elixir ExUnitProperties + Go TUI tests)
make test
```

---

## Running Demos & Interactive Modes

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

### 4. `super-agy` — Antigravity CLI (`agy`) Clone & Go Bubble Tea TUI
`bin/super-agy` (`SuperPi.AGY.CLI`) implements an identical clone of `agy` where every customization subsystem runs as a modular `SuperPi.Extension` behaviour (`Rules`, `Skills`, `HooksJson`, `Permissions`, `SlashCommands`), paired with our native Go 1.27 **Bubble Tea + Lipgloss + Glamour** TUI (`clients/agy-tui`) connected over `SuperPi.RPC.Server`:

```bash
# Launch the full-screen interactive Antigravity Bubble Tea TUI (default)
./bin/super-agy

# Launch the interactive TUI with an initial prompt
./bin/super-agy -i "Explain the 10 context derivation rules in this repo"

# List models, agents, and configured MCP servers from ~/.gemini/config/mcp_config.json
./bin/super-agy models
./bin/super-agy agents
./bin/super-agy mcp list

# Run a single prompt non-interactively (-p) with live skill & rule discovery
./bin/super-agy -p "What skills are available in this workspace?"
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
