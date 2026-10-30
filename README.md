# Super-Pi-BEAM

**Super-Pi-BEAM** is a durable, fault-tolerant general-purpose agent harness (with production coding presets) built on **Erlang/OTP 28** and **Elixir 1.20**. It implements an always-durable, crash-resilient agent architecture natively on the BEAM virtual machine.

---

## Key Capabilities

1. **Unified Always-Durable Engine (`SuperPi.Durable`)**:
   - Runs on **SQLite WAL mode** (`ecto_sqlite3`) by default for single-node CLI/TUI/RPC usage and switches to **PostgreSQL** (`postgrex`) at runtime (`SUPER_PI_STORAGE_BACKEND=postgres`). A distributed BEAM cluster (several nodes, one shared PostgreSQL) is supported; see *Multi-Node Cluster*.
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

The application applies pending database migrations at startup (`config :super_pi, auto_migrate: false` turns this off). For PostgreSQL the database must already exist.

### Using the CLI

```bash
export GEMINI_API_KEY=...          # a configured provider is required (see Model Providers)

bin/super-pi                       # interactive chat in a terminal; one prompt from stdin in a pipe
bin/super-pi chat                  # interactive chat (line REPL, streams text as it arrives; /exit to quit)
bin/super-pi run "explain mix.exs" # one prompt, prints the answer; with no prompt it reads stdin
bin/super-pi -p "hello" --model gemini-3-flash-preview
bin/super-pi -c                    # continue the most recent conversation
bin/super-pi --conversation 12     # resume conversation 12
bin/super-pi --harness super-pi-planner -p "plan the refactor"   # an unknown harness is an error
echo '{"prompt":"hi"}' | bin/super-pi --input-format stream-json  # one JSON result line per input line
bin/super-pi gateway 4000          # the HTTP gateway is a separate command
```

There is no bundled full-screen TUI. `bin/super-pi chat` is a line REPL. A full-screen client can attach through the JSON-RPC server (`bin/super-pi rpc`) or the HTTP gateway. If a `super-pi-tui` executable is on `PATH`, `SuperPi.CLI.launch_interactive_tui/4` starts it against a local RPC server.

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
           "super-pi-workspace": {
             "name": "Super-Pi Workspace Development Harness",
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

   # Run prompt through Workspace harness (with skills, rules, hooks, permissions)
   opencode run "Audit the codebase rules" --model super-pi/super-pi-workspace
   ```
4. **Inspect Durable Sessions**:
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

### JSON-RPC Server

A JSON-RPC 2.0 server exposes sessions to editors and other programs (`session.open`, `session.submit`, `session.watch`, `session.fork`, and more; see `SuperPi.RPC.Server`). One JSON object per line, in both directions.

```bash
bin/super-pi rpc 4001            # TCP on 127.0.0.1 (loopback only)
bin/super-pi rpc --unix /run/user/1000/super-pi.sock   # Unix socket, file mode 0600
bin/super-pi rpc --stdio         # stdin/stdout, for an IDE that starts it as a subprocess
```

In `--stdio` and `mcp` modes stdout carries protocol lines only; logs go to stderr (`SUPER_PI_LOG_STDERR=1`, set by the launcher). With tokens configured, a client must call `auth.login` first (see *Authentication and Ownership*).

### MCP Client: Using Other MCP Servers as Tools

Super-Pi also connects to MCP servers as a client. Servers come from `mcp_config.json` in the global config dir, the file that `super-pi mcp add|remove|enable|disable|list` edits:

```bash
bin/super-pi mcp add files npx -y @modelcontextprotocol/server-filesystem /tmp
```

When a conversation starts, each enabled `command` server is started once (stdio transport), and its tools join the tool list as `mcp__<server>__<tool>`. HTTP transports (`url` entries) are not supported and are skipped with a warning.

MCP tools pass the same permission pipeline as built-in tools. Under the default `accept-edits` mode they are blocked, because they are neither read-only nor file edits. A session must opt in with mode `auto` (or `dangerouslySkipPermissions`) before the model can call them.

```elixir
config :super_pi,
  mcp_clients: true,             # set false to never start servers
  mcp_tool_exposure: :direct,    # :deferred lists them only through `tool_search`
  mcp_startup_timeout_ms: 10_000,
  mcp_call_timeout_ms: 60_000
```

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
- **`SuperPi.Harness.Workspace` (`super-pi-workspace`)**:
  Workspace development persona declaratively assembled from plugins (`SlashCommands`, `Rules`, `Skills`, `Hooks`, `Permissions`, `ProtectedPaths`, `ConfirmDestructive`, `TranscriptLogger`). It is the default harness for the Gateway, RPC and MCP entry points.
- **`SuperPi.Harness.Planner` (`super-pi-planner`)**:
  Read-only architectural planning specialist with write protection.

### Listing Harnesses via CLI

```bash
bin/super-pi harnesses
```

Output:
```text
HARNESS ID            NAME                                              DESCRIPTION
-------------------------------------------------------------------------------------------------------
super-pi-agent        Super-Pi Standard Agent                           Autonomous coding agent with 10-rule context derivation and 4-layer safe sandbox
super-pi-fast         Super-Pi Fast Responder                           High-throughput fast response harness powered by gemini-3-flash-preview for rapid turnarounds
super-pi-auto         Super-Pi Autonomous Enterprise Harness            Autonomous harness composed of security shields, git rollbacks, dynamic model cascading, and task ledge
super-pi-interactive  Super-Pi Human-Collaborative Interactive Harness  Interactive harness composed of clarification questionnaires, inline shell evaluation, terminating outp
super-pi-workspace    Workspace Development Harness                     Workspace development persona with hierarchical rules, progressive skills, lifecycle hooks, permissions
super-pi-planner      Super-Pi Architecture Planner                     Read-only architectural analysis, planning, and verification harness
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

Super-Pi-BEAM includes a library of **19 modular plugins** migrated from the Pi ecosystem and native BEAM patterns. Plugins implement the 12-hook `SuperPi.Extension` behaviour and can be assembled declaratively into any harness (even in separate external repositories):

| Plugin | Module | Impact / Feature |
| :--- | :--- | :--- |
| **`JevRouter`** | `SuperPi.Plugins.JevRouter` | **60–80% token cost reduction**: routes to reasoning model (`pro`) for planning, then cascades to fast model (`flash`) on first edit. |
| **`Handoff`** | `SuperPi.Plugins.Handoff` | **Context transfer**: stores a child conversation seeded with the summary and goal that the model supplies. It does not run the child. |
| **`InlineBash`** | `SuperPi.Plugins.InlineBash` | **Saves 1 round-trip turn**: pre-evaluates `!{command}` expressions in user prompts directly on input. |
| **`StructuredOutput`** | `SuperPi.Plugins.StructuredOutput` | **Zero-waste completion**: provides terminating `structured_output` tool (`control: %{"terminate" => true}`). |
| **`Subagent`** | `SuperPi.Plugins.Subagent` | **`delegate_subagent` tool**: runs a child conversation with its own model loop and returns its final answer. Several `tasks` run concurrently. Roles `scout`, `planner`, `reviewer`, `researcher` are read-only (plan mode); a `worker` inherits the parent's mode and settings and never gains permission. A child cannot delegate further (`subagent_max_depth`, default 1), cannot ask the user, and ends at `subagent_timeout_ms` (default 120 s). The parent waits in the tool call, and `session.cancel` does not yet stop running children. |
| **`Questionnaire`** | `SuperPi.Plugins.Questionnaire` | **`ask_question` tool**: asks the user multiple-choice questions through a connected client (`bin/super-pi chat` asks on the terminal; an RPC client watches with `"interactive": true` and answers with `ui.respond`). With no client able to answer (the HTTP gateway, headless runs) the call fails at once. The conversation waits while a question is open; the wait is not stored across a crash. |
| **`CustomCompaction`** | `SuperPi.Plugins.CustomCompaction` | **Tiered off-model summarization**: offloads compaction to fast models, preserving key decisions and tool cut-points. |
| **`Todo`** | `SuperPi.Plugins.Todo` | **Stateful task ledger**: manages task checklists stored in durable session documents (`pi.live`), surviving branch forks. |
| **`PromptCustomizer`** | `SuperPi.Plugins.PromptCustomizer` | **Adaptive guidance**: injects operational rules tailored specifically to active tools, keeping base prompts compact. |
| **`ProtectedPaths`** | `SuperPi.Plugins.ProtectedPaths` | **Safety shield**: blocks write/edit/read operations on `.env`, `.git/`, private keys, and credentials. |
| **`ConfirmDestructive`** | `SuperPi.Plugins.ConfirmDestructive` | **Execution gate**: intercepts dangerous bash operations (`rm -rf`, `DROP TABLE`, `git reset --hard`). |
| **`GitCheckpoint`** | `SuperPi.Plugins.GitCheckpoint` | **Atomic rollback**: takes git stash checkpoints before tool mutations to support clean fork recovery. |
| **`AutoCommit`** | `SuperPi.Plugins.AutoCommit` | **Turn finalization**: automatically stages and commits modified files when an agent run finishes. |
| **`Rules`** | `SuperPi.Plugins.Rules` | **Repository rules**: injects `AGENTS.md`, `GEMINI.md` and `.agents/rules/*.md` into the system prompt within a token budget. |
| **`Skills`** | `SuperPi.Plugins.Skills` | **Progressive skills**: discovers `SKILL.md` skills across workspace, global and built-in locations and indexes them. |
| **`Hooks`** | `SuperPi.Plugins.Hooks` | **Lifecycle hooks**: runs `hooks.json` commands on `SessionStart`, `PreToolUse`, `PostToolUse` and `Stop`. |
| **`Permissions`** | `SuperPi.Plugins.Permissions` | **Policy engine**: execution modes, command allow and deny lists, workspace confinement (on by default). |
| **`SlashCommands`** | `SuperPi.Plugins.SlashCommands` | **Slash commands**: `/plan`, `/goal`, `/boost`, `/model`, `/mode` expansion on input. |
| **`TranscriptLogger`** | `SuperPi.Plugins.TranscriptLogger` | **Transcripts**: writes JSONL transcripts under the app data directory and manages plugin metadata. |

### Model Providers (`SuperPi.AI.Provider`)

A provider owns one model API. `SuperPi.AI.Providers` picks the provider for a model:

1. In mock mode (`config :super_pi, mock_llm: true`) only the echo provider is active. Mock mode never turns on by itself.
2. Otherwise the first provider in `config :super_pi, :providers` whose `handles?/1` returns true serves the model. The default list is Gemini, Anthropic and OpenAI.
3. A model with no provider, or a provider without credentials, is an error. There is no silent fallback.

| Provider | Models | Key | Notes |
|---|---|---|---|
| Gemini | `gemini-*`, `google/*`, harness aliases | `GEMINI_API_KEY` | Live-tested. |
| Anthropic | `claude-*`, `anthropic/*` | `ANTHROPIC_API_KEY` | Messages API. Extended thinking is **off**; thinking blocks in the history are dropped. `--json-schema` is ignored. Not tested against the live API. |
| OpenAI | `gpt-*`, `o1*`, `o3*`, `o4*`, `openai/*` | `OPENAI_API_KEY` | Chat Completions. `openai_base_url` points it at any compatible server (Azure OpenAI, vLLM, Ollama, a proxy). Not tested against the live API. |

Anthropic and OpenAI settings are `anthropic_base_url`, `anthropic_models`, `anthropic_max_tokens` (default 8192), `anthropic_version`, `openai_base_url`, `openai_models` and `openai_max_tokens`. A model is listed in `/v1/models` and the CLI only when its provider has a key.

Both providers read the stream with `SuperPi.AI.StreamNormalizer`, map text, tool calls and token usage, turn a 429 or 529 into a backoff (`Retry-After`, capped at 60 s), and report the provider's own error message for other failures. They are tested against a local server that replays the documented stream formats (`test/super_pi/ai/anthropic_openai_test.exs`, `provider_turn_test.exs`). The opt-in live tests (`--include live`) have never run with a real key.

To serve an unsupported or exotic model, implement the `SuperPi.AI.Provider` behaviour and register it first in the list:

```elixir
config :super_pi, :providers, [MyApp.MyProvider, SuperPi.AI.Providers.Gemini]
```

### Permissions and Remote Modes

The `Permissions` plugin enforces three execution modes: `plan` (read-only), `accept-edits` (file edits, shell commands only from the allow list) and `auto`. Workspace confinement is on by default (`allowNonWorkspaceAccess: false`). Policy is data: `config :super_pi, :permissions`, `<app data dir>/settings.json`, and the session's `settingsOverride`. `permissions.deny` blocks matching shell commands in every mode.

Gateway, RPC and MCP callers get a limited mode:

```elixir
config :super_pi, :permissions,
  remote_default_mode: "accept-edits",
  remote_max_mode: "accept-edits"
```

A caller may request any mode up to `remote_max_mode`. Gateway callers send the `x-super-pi-mode` header or an `execution_mode` body field. RPC callers set `agent.executionMode`. RPC callers cannot set `dangerouslySkipPermissions`, `settingsOverride` or workspace paths. Without config, a request can only tighten the mode. An unknown harness name is an error. Set `config :super_pi, fallback_harness: "<id>"` for a fallback, and `default_harness` to change the default.

### Observability: Traces, Metrics, Logs

**Traces (OpenTelemetry).** Every conversation turn is a span tree: `super_pi.gateway.request` (when the turn came over HTTP) > `super_pi.turn` > `chat <model>` (one per provider call, with `gen_ai.usage.input_tokens` and `output_tokens`) and `execute_tool <name>`. Failures set the span status to `error`. Prompts, answers and tool arguments are never recorded. Spans are no-ops until you point the app at a collector:

```bash
# for example Jaeger: docker run -p 16686:16686 -p 4318:4318 jaegertracing/all-in-one
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318 OTEL_SERVICE_NAME=super-pi-beam bin/super-pi gateway 4000
# then open http://localhost:16686 and pick the service
```

The exporter is OTLP over HTTP. Other `OTEL_*` variables are read by the OpenTelemetry SDK. A streamed gateway response ends its request span when the headers are sent, so the turn span can outlive it.

**Metrics (Prometheus).** `GET /metrics` on the gateway (same authentication as the API) exposes `super_pi_turn_total`, `super_pi_llm_requests_total`, `super_pi_llm_input_tokens`, `super_pi_llm_output_tokens`, `super_pi_tool_calls_total`, and duration histograms (`*_duration_milliseconds_bucket`), labelled by model, tool and status. The same data is emitted as `:telemetry` events (`[:super_pi, :turn | :llm | :tool, :stop]`), so any `Telemetry.Metrics` reporter can consume it (`SuperPi.Telemetry.metrics/0`).

**Logs.** Log lines from a conversation carry `conversation_id` and `task_id`. In `rpc --stdio` and `mcp` modes logs go to stderr.

### Workspaces and Artifacts

File and command tools act on a **workspace**. The workspace is configuration, set per conversation in `pi.agent["workspace"]` (for example through RPC `session.open` `agent`, or a harness default). Nothing assumes the local disk of the node.

| Kind | Where tools act | Survives node loss | Offered tools |
|---|---|---|---|
| `local` (default) | The node's disk, as before. The permission policy confines paths. | No | file, command |
| `shared` | A directory on storage that every node mounts (NFS, CephFS, a read-write-many volume). `{"kind": "shared", "root": "/mnt/shared/ws"}`. Paths are confined to `root`; writes take a PostgreSQL advisory lock, so two nodes cannot change one file at once. | Yes | file, command, artifacts |
| `scratch` | A temporary directory on the node that runs the task, removed when the task ends (`"lifetime": "conversation"` keeps it until the sweep, `scratch_ttl_hours`, default 24). `"base"` or `config :super_pi, scratch_dir` sets the parent. Paths are confined. | No | file, command, artifacts |
| `none` | No filesystem and no commands (API-style agents). | n/a | artifacts |

A tool that the workspace cannot serve is not offered to the model, and is refused if called. A `shared` workspace without a `root` is an error, not a fall back to the local disk. A task that restarted (a crash or a failover) gets a new, empty scratch directory, and its first tool result says so.

**Artifacts** are the explicit storage API. A scratch directory disappears with its task or node. An artifact does not: it is stored by name, per conversation, in the database (PostgreSQL, or SQLite on a single node).

| Tool | Purpose |
|---|---|
| `artifact_put` | Save text (`content`) or a workspace file (`path`) under `name`. A second put replaces it. |
| `artifact_get` | Return an artifact, or write it into the workspace (`to_path`). |
| `artifact_list` | List the artifacts of the conversation. |

Limits: `artifact_max_bytes` (10 MiB) per artifact and `artifact_max_count` (200) per conversation. The backend is `SuperPi.Artifacts.Store`; set `config :super_pi, artifact_store: MyStore` to use another one, for example an S3-compatible bucket.

**Limits of confinement.** Confinement covers file tools and follows symlinks. A shell command runs with the workspace root as its working directory, but it is not sandboxed: a command can still reach other paths. Use an OS-level sandbox (container, VM) for untrusted commands. Placing a conversation on one node, so that a `scratch` or `local` workspace is where the turn runs, is part of the cluster work (Task 36).

### Production PostgreSQL

"PostgreSQL" here means a separate instance reached over the network: your own server or a managed service (RDS, Cloud SQL, Azure Database, Neon). SQLite stays the default for a single local node.

```bash
export SUPER_PI_STORAGE_BACKEND=postgres
export DATABASE_URL=ecto://app:secret@db.example.com:5432/super_pi
export SUPER_PI_DB_SSL=verify-full           # disable (default) | require | verify-full
export SUPER_PI_DB_SSL_CA=/etc/ssl/rds-ca.pem  # optional; default is the system CA store
export POOL_SIZE=10                          # connections per node
```

| Variable | Meaning |
|---|---|
| `SUPER_PI_DB_SSL` | `require` encrypts but does not check the certificate. `verify-full` checks the chain and the host name. `sslmode=` in `DATABASE_URL` is read when this is unset. |
| `SUPER_PI_DB_SSL_CA`, `SUPER_PI_DB_SSL_SNI` | CA bundle, and the name to verify (default: the host of the URL). |
| `SUPER_PI_DB_SSL_CERT`, `SUPER_PI_DB_SSL_KEY` | Client certificate, for servers that require one. |
| `POOL_SIZE`, `SUPER_PI_DB_QUEUE_TARGET`, `SUPER_PI_DB_QUEUE_INTERVAL` | Pool size per node, and the checkout wait (ms) before the pool sheds load. Total connections are about nodes x pool size, plus Oban's listener. |
| `SUPER_PI_DB_IPV6` | `true` to connect over IPv6. |
| `SUPER_PI_SQLITE_PATH` | SQLite file. A release defaults to the per-user data directory. |

**Migrations.** The development default applies pending migrations at start. A production release does not (`auto_migrate: false`), so a rolling deploy cannot race on the schema. Run the migration as a separate step before the new version takes traffic:

```bash
bin/super_pi eval "SuperPi.Release.migrate()"
bin/super_pi eval "SuperPi.Release.rollback(20261030000001)"   # back to a version
```

`SUPER_PI_AUTO_MIGRATE=true` migrates at boot instead.

**Poolers.** Connect directly, or through a pooler in *session* mode. Transaction-mode pooling (pgbouncer `pool_mode=transaction`) is not supported: Oban waits for jobs with `LISTEN/NOTIFY`, which needs one session, and the driver prepares statements per connection.

**Gateway sessions** (`x-session-id` to conversation) are stored in the `gateway_sessions` table, so they survive a restart and are shared by every node. Idle sessions expire after `gateway_session_ttl_days` (90), and the table keeps at most `gateway_session_limit` rows (100,000).

TLS is tested against a real server: `mix test --only postgres test/super_pi/postgres_tls_test.exs` (see the file for the variables).

### Multi-Node Cluster

A cluster is several BEAM nodes, joined with `libcluster`, that share one PostgreSQL. SQLite is single-node: the application refuses to start with a cluster strategy and `SUPER_PI_STORAGE_BACKEND` other than `postgres`.

| Variable | Meaning |
|---|---|
| `SUPER_PI_CLUSTER_STRATEGY` | `none` (default), `epmd`, `dnspoll`, `kubernetes_dns` or `gossip`. |
| `SUPER_PI_CLUSTER_HOSTS` | `epmd`: comma-separated node names, for example `super_pi@10.0.0.1,super_pi@10.0.0.2`. |
| `SUPER_PI_CLUSTER_DNS_QUERY`, `SUPER_PI_CLUSTER_NODE_BASENAME` | `dnspoll`: the DNS name that lists all nodes, and the node name prefix (default `super_pi`). |
| `SUPER_PI_CLUSTER_K8S_SERVICE` | `kubernetes_dns`: the headless Service name. |
| `SUPER_PI_CLUSTER_GOSSIP_SECRET`, `SUPER_PI_CLUSTER_GOSSIP_PORT` | `gossip`: shared secret and UDP port (default 45892). |
| `SUPER_PI_CLUSTER_POLL_MS` | Polling interval for `dnspoll` and `kubernetes_dns` (default 5000). |
| `RELEASE_NODE`, `RELEASE_COOKIE` | Node name and cookie of a release. Every node needs the same cookie. |

What the cluster guarantees:

- **One machine per conversation.** The machine is registered in `Horde.Registry`, so a request on any node reaches it. `GET /cluster` and `SuperPi.Cluster.status/0` show members and machines per node.
- **Failover.** When the node of a machine stops, `Horde.DynamicSupervisor` starts the machine on another node. It starts in `:recovering`, finds the task that was running and resumes it. A task row records its owner node, so a second node does not reset a turn that is still running.
- **Coherent documents.** After a commit, every node discards cached copies with an older seq.
- **Questions across nodes.** A client on any node can answer a question that a machine on another node asks.
- **Drain.** On SIGTERM a node stops taking turns and finishes the running ones (see *Rolling deploys* in `deploy/README.md`).

Known limits:

- Horde is eventually consistent. During a netsplit two machines can briefly exist for one conversation. The task lease prevents both from running one task.
- Horde sometimes does not restart a machine after a hard node kill. It was seen when the first node of the Horde cluster died: the survivors dropped the machine and started nothing. The next request for the conversation starts it, and recovery resumes the turn. Until then the turn waits.
- A resumed turn can repeat a tool call that ran before the node died.
- `scratch` and `local` workspaces do not survive the loss of a node. Use a `shared` workspace or artifacts (see *Workspaces and Artifacts*).

The multi-node tests start three Erlang nodes against a test PostgreSQL (`make test-cluster`; see the `Makefile` for the variables).

### Deployment

Super-Pi builds as an Elixir release (`mix release super_pi`) and as a Docker image (`docker build -t super-pi .`). Examples for the three common targets are in [`deploy/`](deploy/README.md):

- **Docker / compose:** `deploy/docker-compose.yml` starts PostgreSQL, a one-shot migration and two clustered nodes (`docker compose up`).
- **VMs and Proxmox:** `deploy/vm/` has a systemd unit and an environment file (static `epmd` host list, or `dnspoll`).
- **Kubernetes:** `deploy/kubernetes/super-pi.yaml` has a Deployment, a headless Service for discovery (`kubernetes_dns`), a migration Job, readiness on `/ready` and a PodDisruptionBudget.

A release does not migrate at boot. Run `bin/super_pi eval "SuperPi.Release.migrate()"` first. The gateway starts from `SUPER_PI_GATEWAY=true` (with `SUPER_PI_GATEWAY_BIND`, `SUPER_PI_GATEWAY_PORT`, `SUPER_PI_GATEWAY_TOKEN`). `GET /ready`, `GET /health` and `GET /cluster` support probes and operations.

### Authentication and Ownership

The Gateway and the RPC server are open on loopback by default. To require a key, set tokens in config or the environment:

```elixir
config :super_pi, gateway_tokens: [alice: "key-for-alice", bob: "key-for-bob"]   # or plain strings
```

```bash
export SUPER_PI_GATEWAY_TOKEN="key-one,key-two"
```

- **Gateway.** Send `Authorization: Bearer <key>`. A missing or wrong key gets `401` with the OpenAI error code `invalid_api_key`. `/` and `/health` stay open. The gateway refuses to bind a non-loopback address unless a token is configured.
- **RPC.** With tokens configured, call `auth.login` with `{"token": "..."}` before any other method. Without a valid login the server answers `-32001`.
- **Ownership.** The principal that creates a conversation owns it. Another principal asking for it gets the same answer as for a conversation that does not exist (`-32004` over RPC; a new conversation over the Gateway). Gateway session ids are per principal. A conversation without an owner (created by the CLI) belongs to `anonymous`, so it is reachable only when authentication is off.
- **MCP.** The MCP server runs over stdio for the process that started it. Its `tools/call` goes through the default harness's `before_tool` pipeline (permissions, protected paths), in the remote mode (`accept-edits` unless configured).

### HTTP Gateway Reference (OpenAI-compatible inference endpoint)

**Contract.** The gateway implements the OpenAI **Chat Completions** API (`POST /v1/chat/completions`, `GET /v1/models`) as an *inference provider*. Any client that talks to an OpenAI-compatible provider (OpenCode, the AI SDK, LiteLLM, plain `curl`) can use it with `baseURL = http://127.0.0.1:4000/v1`.

**One difference matters.** The gateway is an agent behind a model-shaped door, not a model proxy. The server runs the agent loop: it calls the LLM, executes tools (`read`, `write`, `edit`, `bash`, ...) itself under the permission policy, and returns the final answer. The client sends a prompt and gets text back. The client does not execute tools.

```bash
bin/super-pi gateway 4000            # loopback only; add --verbose for token-level logs
```

**Endpoints**

| Endpoint | Behavior |
|---|---|
| `GET /` and `GET /health` | Status. Always open. |
| `GET /v1/models` | Harness ids (virtual models) plus models of every configured provider. |
| `POST /v1/chat/completions` | Chat completion, `stream: false` (JSON) or `stream: true` (SSE `chat.completion.chunk` events, ending with `data: [DONE]`). |

**Request**

```bash
curl http://127.0.0.1:4000/v1/chat/completions \
  -H 'Authorization: Bearer <key>' \            # only when tokens are configured
  -H 'x-session-id: my-chat' \                  # keeps one conversation across requests
  -H 'x-super-pi-mode: plan' \                  # optional, can only tighten the permission mode
  -d '{"model": "super-pi-workspace", "stream": true,
       "messages": [{"role": "user", "content": "List the files in lib/"}]}'
```

- `model`: a harness id (a virtual model that picks an agent persona with its own plugins and tools) or a model that a registered provider serves, which is passed through to that provider. Anything else returns `404 model_not_found`. A model whose provider has no key returns `503 provider_not_configured`. `GET /v1/models` lists exactly the accepted values.
- **Sessions.** Conversations are durable and live on the server. Send `x-session-id` (or `session_id` in the body) to continue one, or `x-conversation-id` to attach by id. The session-id-to-conversation map is stored in the database, so it survives a restart. The first request of a session seeds the prior `messages`. Later requests use only the **last user message**, because the server already holds the history. Without a session id, every request starts a new conversation.
- **Streaming.** Answer text arrives as `delta.content`. Reasoning and tool progress arrive as `delta.reasoning_content`, so a client can show them without mixing them into the answer. `usage` is reported once. A failed turn ends with `finish_reason: "error"`.
- **Errors** use the OpenAI shape `{"error": {"message", "type", "code"}}`: `400 invalid_params`, `401 invalid_api_key`, `404 model_not_found`, `503 provider_not_configured`.
- **Authentication, ownership and modes**: see *Authentication and Ownership* and *Permissions and Remote Modes*.

**Limitations**

| Not supported | What happens |
|---|---|
| Client-defined `tools`, `tool_choice`, `functions` | Ignored. The agent uses its own server-side tools. The response never contains `tool_calls`. |
| `temperature`, `top_p`, `max_tokens`, `stop`, `seed`, `n`, `stream_options`, `response_format` | Ignored. One choice is returned. Use harness and agent configuration instead. |
| Images and other non-text content parts | Dropped. Only text is read. |
| `/v1/completions`, `/v1/embeddings`, `/v1/responses`, `/v1/audio/*`, `/v1/images/*` | `404`. |
| Replaying history from the client | Later requests in a session use only the last user message. Edited or regenerated earlier messages are not applied. |
| Concurrent requests on one session | Queued by the conversation, not run in parallel. |
| A model that is not a harness or provider model | `404 model_not_found`. There is no silent fallback. |
| Rate limits, quotas, per-key budgets | None. |
| TLS | None. Put a reverse proxy in front for a non-loopback bind. |
| Multi-node serving | Supported with PostgreSQL (see *Multi-Node Cluster*). A load balancer may send a request to any node. |
| Token counts for streamed turns | Reported from the provider when it gives them. Not estimated. |

### Paths

No path is hardcoded. Global config, app data and extra discovery roots resolve from app config, then the environment (`SUPER_PI_CONFIG_DIR`, `SUPER_PI_DATA_DIR`, `SUPER_PI_DISCOVERY_ROOTS`), then the operating system default (`:filename.basedir/2`). See `SuperPi.Discovery`.

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
| **Tier 2: Environment Variables** | `.env` / Shell Environment | **Secrets & Infrastructure Adapters**: API tokens (`GEMINI_API_KEY`, `SUPER_PI_GATEWAY_TOKEN`), database engine selection (`SUPER_PI_STORAGE_BACKEND=postgres`, `DATABASE_URL`), tracing (`OTEL_EXPORTER_OTLP_ENDPOINT`), fast operational overrides (`JEV_PLANNING_MODEL`, `JEV_IMPLEMENTATION_MODEL`), and host-specific path rules (`PROTECTED_PATHS`). Never committed. |
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

Super-Pi-BEAM uses **`ExUnitProperties` (`StreamData`)** property-based testing across the core subsystems, plus unit and integration tests.

```bash
mix test                                   # whole suite on SQLite
mix test test/super_pi/properties          # property tests only
mix test --seed 0                          # fixed seed; a failure prints the shrunk input
```

**PostgreSQL.** The same suite runs on PostgreSQL. Two more kinds of test need a real server and are excluded by default:

```bash
export SUPER_PI_STORAGE_BACKEND=postgres
export DATABASE_URL=ecto://user:pass@localhost/super_pi_test   # the database must exist
mix test                                   # whole suite on PostgreSQL

# Real-concurrency tests and the migration property (tag :postgres).
# The migration property migrates down, so give it its own scratch database.
export SUPER_PI_MIGRATION_TEST_URL=ecto://user:pass@localhost/super_pi_migration
mix test --only postgres
```

**Live providers.** Smoke tests against real provider APIs (cost money, need network) run only when asked and skip without a key:

```bash
GEMINI_API_KEY=... mix test --include live test/super_pi/ai/live_provider_test.exs
```

Run the SQLite suite with `mix test`, the PostgreSQL suite with `SUPER_PI_STORAGE_BACKEND=postgres mix test`, the `:postgres` tests with `--only postgres`, and the multi-node suite with `make test-cluster`. The project has no CI service configuration.

---

## Project Structure

```text
lib/
├── super_pi.ex
├── super_pi/
│   ├── ai/
│   │   ├── gemini_client.ex       # Live Google Gemini SSE streaming & tool-calling client
│   │   ├── provider.ex            # Provider behaviour (escape hatch for custom models)
│   │   ├── providers.ex           # Provider registry, fail-closed resolution, model catalog
│   │   ├── providers/             # Gemini, Anthropic, OpenAI and Mock providers, shared SSE client
│   │   ├── tool_schemas.ex        # JSON Schema for the built-in tools
│   │   ├── stream_normalizer.ex   # Multi-provider SSE normalizer & partial JSON repair
│   │   └── virtual_model.ex       # Virtual model router & UUIDv7 session affinity
│   ├── auth.ex                    # Bearer tokens and conversation ownership
│   ├── cli.ex                     # Unified CLI (run, chat, flags, subcommands)
│   ├── cluster.ex                 # Cluster configuration and status (libcluster topologies)
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
│   ├── discovery.ex               # Config, data and discovery paths (app env, env vars, OS defaults)
│   ├── extension.ex               # Unified 12-hook extension behaviour & pipeline
│   ├── gateway/
│   │   ├── router.ex              # OpenAI-compatible HTTP Gateway with SSE streaming
│   │   └── server.ex              # Bandit listener; refuses a non-loopback bind without a token
│   ├── harness/                   # Pluggable harness personas (Default, Fast, Autonomous, Interactive, Workspace, Planner)
│   │   ├── autonomous.ex          # Enterprise autonomous harness with Jev cascading & auto-commit
│   │   ├── default.ex             # Standard autonomous coding agent harness
│   │   ├── interactive.ex         # Human-in-the-loop interactive harness with questionnaires & handoffs
│   │   ├── fast.ex                # Low-latency harness
│   │   ├── planner.ex             # Read-only architectural planning harness
│   │   └── workspace.ex           # Declarative workspace harness (rules, skills, hooks, permissions, slash commands)
│   ├── harness.ex                 # SuperPi.Harness behaviour contract & resolver
│   ├── mcp/
│   │   ├── client.ex              # MCP client for one stdio server
│   │   ├── manager.ex             # Starts configured MCP servers, exposes mcp__<server>__<tool>
│   │   └── server.ex              # Model Context Protocol stdio server
│   ├── plugins/                   # 19 reusable plugins (JevRouter, Handoff, Permissions, Rules, Skills, etc.)
│   ├── plugins.ex                 # SuperPi.Plugins registry, aliases, & option resolver
│   ├── repo.ex                    # Runtime-switchable SQLite3 / Postgrex Ecto repo facade
│   ├── repo/
│   │   └── migrator.ex            # Applies pending migrations at startup
│   ├── rpc/
│   │   └── server.ex              # JSON-RPC 2.0 server with K=2 ack-clocked backpressure
│   ├── telemetry.ex               # OpenTelemetry spans and Prometheus metrics
│   ├── tools.ex                   # 7 built-in 3-channel tools & 5 ToolExposure modes
│   ├── tui/
│   │   └── owl.ex                 # Interactive Owl terminal UI
│   ├── ui/
│   │   └── broker.ex              # Routes ask_question requests to a client and answers back
│   └── workers/
│       └── oban_workers.ex        # Oban workers (generation_retry, compaction, verification, subagents)
examples/
├── gemini_live_demo.exs           # Live Gemini 3 Flash tool-calling demo
├── interactive_tui.exs            # Interactive Owl TUI loop
└── rpc_showcase_client.exs        # External JSON-RPC 2.0 client showcase
test/                              # ExUnitProperties property-based & integration test suites
```
