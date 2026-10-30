# Super-Pi-BEAM

**Super-Pi-BEAM** is a durable, fault-tolerant, general-purpose agent framework built on **Erlang/OTP 28** and **Elixir 1.20**. It implements an always-durable, crash-resilient agent architecture natively on the BEAM virtual machine.

Four built-in harnesses show what the engine does. `super-pi-code` changes a repository and can undo the change. `super-pi-assistant` works with a person, reaches the web and third-party services, and has no filesystem. `super-pi-librarian` runs with no person present and remembers across sessions. `super-pi-planner` cannot write. Three optional capability blocks (web access, scheduling, durable memory) can join any harness. Every interface (OpenAI gateway, JSON-RPC, MCP, ACP, AG-UI, terminal) renders one typed event stream.

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
   - **Background Queues (`Oban`)**: 6 queues (`:generation_retry`, `:compaction`, `:verification`, `:subagents`, `:schedule_tick`, `:schedule_runs`) and one cron entry that ticks the scheduler every minute.

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

7. **One Typed Event Stream, Many Interfaces (`SuperPi.Event`)**:
   - The conversation machine publishes typed events (`turn_started`, `text_delta`, `tool_started`, `permission_request`, `turn_completed`, and more). Each interface renders them through a pure state machine (`SuperPi.Event.Renderer`): OpenAI SSE, JSON-RPC, the chat terminal, **ACP** (editors such as Zed and JetBrains), and **AG-UI** (web front ends). See *Interfaces*.

8. **Human Approval Without Blocking the Machine**:
   - A blocked tool call can ask a person. The question travels as a `permission_request` event, and the answer decides the call. With no client to ask, the call stays blocked, with the same message as before. See *Permissions and Remote Modes*.

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
bin/super-pi --harness assistant -p "summarize https://example.com"   # short ids work too
bin/super-pi acp                   # an Agent Client Protocol agent over stdio, for Zed, JetBrains and others
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
           "super-pi-code": {
             "name": "Super-Pi Code",
             "limit": { "context": 128000, "output": 8192 }
           },
           "super-pi-assistant": {
             "name": "Super-Pi Assistant",
             "limit": { "context": 128000, "output": 8192 }
           },
           "super-pi-librarian": {
             "name": "Super-Pi Librarian",
             "limit": { "context": 128000, "output": 8192 }
           },
           "super-pi-planner": {
             "name": "Super-Pi Planner",
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

   # Run a prompt through the assistant (no filesystem)
   opencode run "What is 15 plus 27?" --model super-pi/super-pi-assistant

   # Run a prompt through the coding harness (rules, skills, hooks, permissions)
   opencode run "Audit the codebase rules" --model super-pi/super-pi-code
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

### MCP: Client and Server

Super-Pi-BEAM is an MCP client and an MCP server. Both sides speak the protocol versions `2025-06-18`, `2025-03-26` and `2024-11-05`. The server does not support `2026-07-28`.

#### Use MCP servers (client)

`super-pi mcp add|remove|enable|disable|list` edits `<global config dir>/mcp_config.json`. Each entry under `"mcpServers"` has one of two shapes.

A local process over stdio:

```json
{
  "mcpServers": {
    "files": { "command": "npx", "args": ["-y", "some-server"], "env": { "TOKEN": "..." } }
  }
}
```

A hosted server over Streamable HTTP:

```json
{
  "mcpServers": {
    "docs": {
      "url": "https://mcp.example.com/mcp",
      "headers": { "Authorization": "Bearer ${DOCS_TOKEN}" }
    }
  }
}
```

| Command | Entry written |
|---|---|
| `super-pi mcp add files my-mcp-server` | `command` (and `args` for the words after it) |
| `super-pi mcp add docs https://mcp.example.com/mcp` | `url` |

Rules for `url` entries:

- `serverUrl` is accepted as an alias of `url`.
- `headers` is a map. `${ENV_VAR}` in a value is replaced from the environment when the server starts. A variable that is not set fails that server with `{:missing_env, [...]}`, and the other servers still start.
- OAuth is not supported. Put a bearer token in `Authorization`.
- An entry with both `command` and `url` runs the command.
- `"disabled": true` skips an entry.

Transport behavior (`SuperPi.MCP.Transport.StreamableHTTP`):

- The server may answer a `POST` with `202`, with JSON, or with `text/event-stream`. All three work.
- The client sends `Mcp-Session-Id` and `MCP-Protocol-Version` on every request after `initialize`.
- When the server answers `404` for a session, the client runs the handshake again once and repeats the request.
- When the first `POST` gets `405` (or `404`), the client falls back to the deprecated HTTP+SSE transport. It refuses an `endpoint` on another origin.
- When the client stops, it sends `DELETE` to end the session.

Tools join the catalog as `mcp__<server>__<tool>`. Each tool carries an `effects` list, which the permission policy uses:

| Server annotation | Effects | `plan` | `accept-edits` | `auto` |
|---|---|---|---|---|
| `readOnlyHint: true` | `net_read` | allowed | allowed | allowed |
| anything else | `net_write` | blocked | prompt | allowed |

The `network` setting (`deny`, `allowlist`) applies to every MCP tool, stdio tools included.

#### Use Super-Pi as an MCP server

Over stdio, set the host's command to `super-pi mcp` (with no arguments). Over HTTP, the gateway serves the endpoint `POST /mcp`. Gateway authentication, drain and TLS apply to it.

```json
{
  "mcpServers": {
    "super-pi": {
      "url": "http://127.0.0.1:4000/mcp?harness=super-pi-code",
      "headers": { "Authorization": "Bearer ${SUPER_PI_GATEWAY_TOKEN}" }
    }
  }
}
```

| Request | Answer |
|---|---|
| `POST` with a request | `200`, JSON (or one SSE event when the client accepts only `text/event-stream`) |
| `POST` with notifications only | `202` |
| `initialize` | also returns `Mcp-Session-Id` |
| `GET` | `405` (the server pushes no messages) |
| `DELETE` | `200`, ends the session |

- A request without a session id gets `400`. An unknown or expired session gets `404`, and the client starts a new one.
- A session belongs to the principal that opened it. Sessions live on one node. Limits: `mcp_session_ttl_ms` (1 hour), `mcp_max_sessions` (1000).
- With no gateway token configured, a request with a foreign `Origin` header gets `403`. Loopback origins pass. Add others with `config :super_pi, :mcp_allowed_origins, [...]`.
- `?harness=<id>` on the `initialize` request selects the harness of direct tool calls. Without it, the server uses `config :super_pi, :mcp_harness`, then the default harness.

What the server offers:

- **Tools.** `read`, `write`, `edit`, `bash`, `grep`, `find`, `ls` and `harness_task`. Each has the annotations `readOnlyHint`, `destructiveHint`, `idempotentHint` and `openWorldHint`. Results carry `structuredContent` when the tool returns structured data.
- **Harness selection.** `harness_task` takes `prompt` and an optional `harness` (an id from `prompts/list`). It returns `structuredContent` with `harness` and `conversation_id`.
- **Prompts.** One prompt per harness, plus the alias `plan_architecture`. Each takes a `goal`.
- **Resources.** `superpi://workspace/context`, `superpi://workspace/tools`, and the conversations that this connection started.
- **Resource template.** `superpi://conversation/{id}/transcript` returns the transcript as JSON lines. Another principal does not find the conversation.

The server logs the `protocolVersion` that each host requests at debug level. Set the log level to `debug` and connect a host to see which version the host asks for.

```elixir
config :super_pi,
  mcp_clients: true,             # set false to never start servers
  mcp_tool_exposure: :direct,    # :deferred lists them only through `tool_search`
  mcp_startup_timeout_ms: 10_000,
  mcp_call_timeout_ms: 60_000
```

A client that starts an ACP session can hand over `mcpServers` (stdio and HTTP). `SuperPi.MCP.Manager.add_servers/1` starts them and adds their tools to the catalog.

### The Event Stream (`SuperPi.Event`)

A conversation publishes typed events on the PubSub topic `conversation:<id>` as `{:conversation_event, id, wire_map}`. One struct, with one builder function per type, defines them. Each event has `type`, `conversation_id`, `turn_id` (the id of the turn task), `timestamp_ms` and `v` (schema version, `1`). The payload keys stay at the top level of the wire map, so a consumer that read the earlier untyped maps keeps working.

| Group | Types |
|---|---|
| Turn | `turn_started`, `turn_completed` (with `stop_reason`), `turn_error`, `turn_cancelled` |
| Streaming | `text_delta`, `thinking_delta`, `toolcall_delta`, `message_completed`, `stream_reset` |
| Tools | `tool_started`, `tool_blocked`, `tool_completed` |
| Questions | `permission_request`, `ui_request`, `ui_resolved` |
| State | `state_changed`, `mode_changed`, `usage_updated`, `plan_updated`, `compaction_completed`, `notice` |

The machine publishes the turn events itself, so every consumer sees them, whoever submitted the turn. A *renderer* turns events into the output of one protocol. A renderer is a pure state machine (`init/1`, `render/2`, `flush/1`), not a process. The transport owns the socket and the renderer owns only its projection state, so a renderer needs no socket in a test.

| Renderer | Output |
|---|---|
| `SuperPi.Event.Renderer.OpenAI` | `chat.completion.chunk` maps for the Gateway SSE stream |
| `SuperPi.Event.Renderer.RPC` | the wire map (identity) |
| `SuperPi.Event.Renderer.TUI` | tagged terminal items (`{:text, ...}`, `{:permission, ...}`) |
| `SuperPi.Event.Renderer.ACP` | `session/update` payloads and `session/request_permission` params |
| `SuperPi.Event.Renderer.AGUI` | AG-UI event maps |

### ACP: Use Super-Pi in Zed, JetBrains and Other Editors

`bin/super-pi acp` runs an [Agent Client Protocol](https://agentclientprotocol.com) agent over stdio. The editor starts it as a subprocess. For Zed (`settings.json`):

```json
{
  "agent_servers": {
    "Super-Pi": { "command": "/path/to/super-pi-beam/bin/super-pi", "args": ["acp"] }
  }
}
```

ACP is bidirectional: the agent also sends requests to the editor and waits. `SuperPi.ACP.Server` keeps a table of outstanding requests for that. It does not reuse the JSON-RPC server, which only answers.

| ACP | Super-Pi |
|---|---|
| `initialize` | Agent capabilities, `authMethods` (a token when the gateway needs one), the harness capabilities in `_meta.superPi.harnesses` |
| `session/new` | A conversation with `workspacePaths: [cwd]`. `_meta.harness` selects the harness (default: `super-pi-code`). The `sessionId` is an opaque string (`acp_...`), stored in the session table, so an editor can resume it after a restart |
| `session/load` | Resumes the conversation and replays its history as `session/update` notifications |
| `_superpi/session/fork` | Forks the conversation at its latest entry into a new session |
| `session/prompt` | Runs in a supervised task, so `session/cancel` can arrive during the prompt. `stopReason`: `end_turn`, `cancelled`, or `refusal` for an error |
| `session/cancel` | Cancels pending questions first, then the turn |
| `session/set_mode` | `plan`, `accept-edits` or `auto`, up to the remote ceiling and the harness ceiling |
| `session/request_permission` | The `permission_request` event, with the four ACP option kinds |

Super-Pi does not delegate `terminal/*` to the editor. `SandboxRunner` gives process-group kill, output spill and the sandbox, and an editor terminal gives none of that and bypasses `permissions.deny`. A running command shows as a tool call of kind `execute`. File reads use the editor only for the unsaved buffer: `config :super_pi, :acp, fs_delegation: :unsaved_only | :never | :always` (default `:unsaved_only`). `SuperPi.Env.ClientFS` asks the editor only when the editor advertised `fs/read_text_file`, the machine runs on the same node, and the path is inside the workspace. Writes stay on the server. A minimal client is in `examples/acp_client.exs`.

### AG-UI: Stream a Run to a Web Front End

The Gateway also serves [AG-UI](https://docs.ag-ui.com) over Server-Sent Events. It uses the same authentication, drain and trace plugs as the OpenAI routes.

| Route | Does |
|---|---|
| `POST /agui/v1/run` | Body: a `RunAgentInput` (`threadId`, `runId`, `messages`, optional `forwardedProps` with `harness` and `executionMode`). Streams the run. This is the shape that `@ag-ui/client`'s `HttpAgent` expects. |
| `GET /agui/v1/sessions/:id/events` | Attaches to a live conversation: `STATE_SNAPSHOT`, `MESSAGES_SNAPSHOT`, then live events. |
| `POST /agui/v1/sessions/:id/input` | `{"type": "prompt" \| "permission" \| "answer" \| "cancel", ...}`. |

Mapping: `text_delta` becomes `TEXT_MESSAGE_START` and `TEXT_MESSAGE_CONTENT`. `thinking_delta` becomes the `REASONING_*` events. `toolcall_delta` becomes `TOOL_CALL_START` and `TOOL_CALL_ARGS`. `tool_started` becomes `TOOL_CALL_END`, because in AG-UI that event means *arguments complete*. `tool_completed` becomes `TOOL_CALL_RESULT`. The turn events become `RUN_STARTED`, `RUN_FINISHED` and `RUN_ERROR`. `compaction_completed` becomes `MESSAGES_SNAPSHOT`. `permission_request` and `ui_request` become `CUSTOM` events.

State goes out as `STATE_SNAPSHOT` (status, mode, model, usage, plan, pending permission) and then `STATE_DELTA` events, JSON Patch computed in the renderer. The durable document layer does not give a patch stream: only `pi.agent` keeps ops, and `pi.live` and `pi.usage` do not. After a disconnect, `GET .../events` sends a fresh snapshot. The snapshot covers whatever the gap lost. There is no ack window as in the JSON-RPC server: SSE is one-way, and a failed write cancels the turn. Deltas within about 16 ms merge into one content event. A client is in `examples/agui_client.exs`.

## Pluggable Harness Architecture (`SuperPi.Harness`)

A harness is a named persona. It is a plugin set plus defaults for the conversation's `pi.agent` document (model, effort, mode, workspace, tools, system prompt). The core engine knows nothing about personas. Every persona implements the `SuperPi.Harness` behaviour:

```elixir
defmodule SuperPi.Harness do
  @callback id() :: String.t()
  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback extensions(keyword()) :: list(module() | {module(), term()})
  @callback agent_defaults(keyword()) :: map()
  @callback capabilities() :: map()            # optional
end
```

`capabilities/0` is a machine-readable summary (id, plugins, tool loadout, workspace kind, modes). `GET /v1/models`, `bin/super-pi harnesses`, RPC `workspace.metadata` and ACP `initialize` use it. A harness without it still works: `SuperPi.Harness.capabilities/1` builds a summary from its metadata.

### Built-in Harnesses

| Harness | Id | The line that separates it |
|---|---|---|
| `SuperPi.Harness.Code` | `super-pi-code` | **Changes a repository, and can undo the change.** `GitCheckpoint` and `AutoCommit` (off by default), rules, skills, hooks, slash commands, model cascading (`JevRouter`). |
| `SuperPi.Harness.Assistant` | `super-pi-assistant` | **Works with a person and reaches the web.** `Questionnaire`, `StructuredOutput`, `Handoff`, `Subagent`, `Web`, `CustomCompaction`. Workspace kind `none`: no file tools, no shell. Its tools are MCP connectors (hosted over HTTP) and the web. |
| `SuperPi.Harness.Librarian` | `super-pi-librarian` | **Runs with no person present, and remembers.** `Memory`, `Scheduler`, `Web`. The tool loadout has no `bash`. Workspace roots come from `config :super_pi, :knowledge_paths`. |
| `SuperPi.Harness.Planner` | `super-pi-planner` | **Cannot write.** Read-only tools, mode `plan` with ceiling `plan`, workspace confinement, protected paths. |

All four carry `Permissions`. `Code`, `Librarian` and `Planner` also carry `ProtectedPaths`. The safety floor is the same everywhere, so it does not separate the harnesses.

`Assistant` has no `InlineBash`. That plugin runs `!{...}` outside the tool pipeline, so a workspace without a shell would still reach one.

**Older ids still work.** `super-pi-workspace` and `super-pi-auto` resolve to `super-pi-code`. `super-pi-agent`, `super-pi-fast` and `super-pi-interactive` resolve to `super-pi-assistant`. `super-pi-fast` no longer sets a low effort: pass `--effort low`. Discovery lists only the four current harnesses (`bin/super-pi harnesses`, `GET /v1/models`), while resolution accepts the old ids.

### Listing Harnesses via CLI

```bash
bin/super-pi harnesses
```

Output:
```text
HARNESS ID          NAME                DESCRIPTION
-----------------------------------------------------------------------
super-pi-code       Super-Pi Code       Repository coding agent: reversible edits, rules, skills, hooks, model cascading
super-pi-assistant  Super-Pi Assistant  Assistant for knowledge work: questions, web access, MCP connectors and delegation, no filesystem
super-pi-librarian  Super-Pi Librarian  Durable knowledge curation with scheduled capture, recall and web ingest
super-pi-planner    Super-Pi Planner    Read-only architectural analysis, planning, and verification
```

`--agent` is a deprecated alias of `--harness`: `--agent self` selects `super-pi-code` and `--agent research` selects `super-pi-planner`. `--mode` never raises a harness above its ceiling (`maxExecutionMode`), so `--harness planner --mode auto` stays in `plan`.

### Declaring a Harness

`use SuperPi.Harness` defines the behaviour from a short declaration:

```elixir
defmodule MyApp.Harness.Triage do
  alias SuperPi.Plugins

  use SuperPi.Harness,
    id: "my-triage",
    name: "Triage",
    description: "Sorts incoming tickets",
    effort: "low",
    mode: "accept-edits",
    max_mode: "accept-edits",
    workspace: %{"kind" => "none"},
    tools: {:only, ["todo"]},
    prompt: "You triage tickets.",
    plugins: [Plugins.Todo, Plugins.Permissions]
end
```

| Option | Meaning |
|---|---|
| `:id`, `:name`, `:description` | Required. |
| `:plugins` | Plugin specs (`Module` or `{Module, opts}`). The order matters for `before_compact`: the first plugin that does not answer `:default` ends the chain. |
| `:effort`, `:mode`, `:model` | Defaults for `pi.agent`. |
| `:max_mode` | The highest `executionMode` the harness allows. `Permissions` enforces it. |
| `:workspace` | `:local` (default), `:knowledge_paths`, or a `"workspace"` map such as `%{"kind" => "none"}`. |
| `:tools` | `:all`, `{:only, names}` or `{:except, names}`. |
| `:prompt` | The core system prompt. |

Each setting resolves in one order: the caller's options, then the harness declaration, then the application environment, then a fallback. The model comes from `config :super_pi, :default_model` (fallback `gemini-3-flash-preview`). The workspace roots come from `config :super_pi, :workspace_paths`, then the working directory. Register the module with `config :super_pi, extra_harnesses: [MyApp.Harness.Triage]`.

### A General-Purpose Engine

The runtime does not depend on software engineering:
- **Universal kernel.** State machines (`:gen_statem`), transactional persistence (SQLite or PostgreSQL), crash-immune execution (`SuperPi.Env`) and the streaming protocols run without domain logic.
- **Domain through harnesses.** A harness sets the domain with its prompt, plugins and tool loadout.
- **Examples in the box.** `super-pi-assistant` (knowledge work over MCP connectors and the web) and `super-pi-librarian` (a knowledge base that grows and answers unattended) need no repository.

### Declarative Plugins Ecosystem (`SuperPi.Plugins`)

Super-Pi-BEAM includes a library of **22 modular plugins** migrated from the Pi ecosystem and native BEAM patterns. Plugins implement the 12-hook `SuperPi.Extension` behaviour and can be assembled declaratively into any harness (even in separate external repositories):

| Plugin | Module | Impact / Feature |
| :--- | :--- | :--- |
| **`JevRouter`** | `SuperPi.Plugins.JevRouter` | **60–80% token cost reduction**: routes to reasoning model (`pro`) for planning, then cascades to fast model (`flash`) on first edit. |
| **`Handoff`** | `SuperPi.Plugins.Handoff` | **Context transfer**: stores a child conversation seeded with the summary and goal that the model supplies. It does not run the child. |
| **`InlineBash`** | `SuperPi.Plugins.InlineBash` | **Saves 1 round-trip turn**: pre-evaluates `!{command}` expressions in user prompts directly on input. |
| **`StructuredOutput`** | `SuperPi.Plugins.StructuredOutput` | **Zero-waste completion**: provides terminating `structured_output` tool (`control: %{"terminate" => true}`). |
| **`Subagent`** | `SuperPi.Plugins.Subagent` | **`delegate_subagent` tool**: starts child conversations and returns at once. Each child runs as an Oban job (`SubagentWorker`, queue `:subagents`) on any node. The parent parks in `:awaiting_children` and still answers `cancel`, `get_state` and `compact`. When the children end, their summaries arrive as separate messages and the turn goes on. Roles `scout`, `planner`, `reviewer`, `researcher` are read-only (plan mode). A `worker` inherits the parent's mode and settings and never gains permission. A child cannot delegate further (`subagent_max_depth`, default 1), cannot ask the user, and ends at `subagent_timeout_ms` (default 120 s). `session.cancel` aborts the whole subtree. |
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
| **`Hooks`** | `SuperPi.Plugins.Hooks` | **Lifecycle hooks**: runs `hooks.json` commands on `SessionStart`, `PreToolUse`, `PostToolUse` and `Stop`. A `PreToolUse` hook that answers `"decision": "ask"` asks a person when a client can answer, and blocks the call otherwise. |
| **`Permissions`** | `SuperPi.Plugins.Permissions` | **Policy engine**: execution modes, a ceiling per harness, tool effects, a network policy, command allow and deny lists, workspace confinement (on by default), and questions to a person (see *Permissions and Remote Modes*). |
| **`SlashCommands`** | `SuperPi.Plugins.SlashCommands` | **Slash commands**: `/plan`, `/goal`, `/boost`, `/model`, `/mode` expansion on input. |
| **`Memory`** | `SuperPi.Plugins.Memory` | **Durable notes**: tools `memory_write`, `memory_search`, `memory_read` and `memory_link` over a `memories` table that outlives a conversation. A budgeted index of titles and topics goes into the system prompt (`memory_index`), and the text changes only when a note changes, so it keeps the prompt cache. Search is lexical: FTS5 on SQLite, a generated `tsvector` with GIN on PostgreSQL, `LIKE` as fallback, and `details.backend` names the one that answered. Ranking blends text rank, a 30-day recency half-life and a pinned bonus, and a superseded note ranks below its superseder. A write returns similar notes so the store does not fill with duplicates. On compaction a background job asks the fast model for durable facts and stores them with low confidence (`before_compact` always answers `:default`, so list `Memory` before `CustomCompaction`). Notes are scoped to the conversation's owner (`scope: :global` shares them), are not forked or rewound, and a read-only subagent cannot write them (`state_write` is blocked in plan mode). |
| **`Scheduler`** | `SuperPi.Plugins.Scheduler` | **Unattended runs**: `schedule_create`, `schedule_list`, `schedule_cancel`, and webhook triggers. Exactly-once on SQLite and PostgreSQL. See *Scheduler*. |
| **`Web`** | `SuperPi.Plugins.Web` | **Web access**: `web_fetch` always, `web_search` when a search provider is configured. A request-forgery policy checks every URL and every redirect. The size cap counts decoded bytes. See *Web access*. |
| **`TranscriptLogger`** | `SuperPi.Plugins.TranscriptLogger` | **Transcripts**: writes JSONL transcripts under the app data directory and manages plugin metadata. |

### Capability Blocks

Three plugins add a capability that any harness can compose. Each is optional. They add their tools to a conversation through `before_agent_start` and serve the calls in `wrap_tool`, so a harness that does not load a plugin never offers its tools. Each tool states its effects, so `Permissions` and the workspace treat it correctly (see *Permissions and Remote Modes*).

| Block | `super-pi-code` | `super-pi-assistant` | `super-pi-librarian` | `super-pi-planner` |
|---|---|---|---|---|
| `Web` | off | on | on | off |
| `Scheduler` | off | off | on | off |
| `Memory` | off | optional | on | off |

`Scheduler` belongs to the librarian only. Unattended execution is what makes that harness different. To add `Memory` to the assistant, list `{Plugins.Memory, []}` before `Plugins.CustomCompaction` in a harness of your own.

#### Web access

`SuperPi.Plugins.Web` gives an agent `web_fetch`, and `web_search` when a search provider is configured. The Assistant harness loads it with `{Plugins.Web, tools: [:fetch, :search]}`, the Librarian bare.

| Tool | Arguments | Effect |
|---|---|---|
| `web_fetch` | `url`, `format` (`markdown`, `text`, `raw`), `max_chars`, `offset`, `artifact` | `net_read` |
| `web_search` | `query`, `max_results` | `net_read` |

There is no `headers` argument. A long page is cut at `max_chars` (default 20,000, most 100,000) with a note that names the `offset` to continue from. `artifact` saves the full text under a name instead of returning it. A text over 200,000 characters is saved automatically. A PDF or other binary file is refused unless `artifact` is set.

`web_fetch` returns the page in `output`, metadata in `structured_output` (`final_url`, `status`, `content_type`, `bytes`, `chars`, `truncated`, `title`, up to 30 `links`, `artifact`) and the redirect chain, resolved address and duration in `details`. A 4xx or 5xx status, a refused URL or content type, and a timeout set `is_error`.

**Request-forgery policy.** A URL is refused when it has credentials, a scheme other than `http` or `https`, or a port other than 80 and 443. The host must not be `localhost`, `*.local`, `*.internal` or `metadata.google.internal`, and ANY address it resolves to must be global unicast. Loopback, private, link-local (including `169.254.169.254`), CGNAT, multicast and IPv6 ULA and link-local addresses are refused, and IPv4-mapped, NAT64 and 6to4 forms are checked as the IPv4 address inside. Redirects are followed by the tool, at most five, with the full check on every hop.

**Residual risk.** DNS can answer differently between the check and the connect (rebinding). `pin_ip: true` in the plugin's `fetch:` options connects to the checked address, but it is off by default and not verified against the installed Req, Finch and Mint. Where the window is not acceptable, set `network: "allowlist"` or route egress through a filtering proxy.

**Limits.** The size cap counts decoded bytes: the response streams undecoded, and the tool inflates `gzip` and `deflate` itself and stops at `max_bytes` (default 2 MiB, at most 8 MiB), so a gzip bomb cannot grow the heap. The fetch and the HTML conversion run under `SandboxRunner.run_isolated/2` (deadline and heap limit). Requests use their own Finch pool, `SuperPi.WebFinch`.

**Permissions.** `net_read` is allowed in `plan` (unless `network_in_plan_mode: false`), `accept-edits` and `auto`. `network: "deny"` refuses both tools. `network: "allowlist"` checks the `url` host, so `web_search` is refused under it. A workspace with `"network": false` does not offer them.

**Search providers.** `web_search` exists only when a provider has its key or URL. Set one with the plugin option `search:`, `config :super_pi, :web_search`, or `SUPER_PI_WEB_SEARCH`.

| Provider | Value | Credentials |
|---|---|---|
| Brave Search | `brave` | `BRAVE_API_KEY` |
| Tavily | `tavily` | `TAVILY_API_KEY` |
| SearxNG (JSON format enabled) | `searxng` | `SEARXNG_URL` |

```elixir
{Plugins.Web, tools: [:fetch, :search], search: {:brave, api_key: System.fetch_env!("BRAVE_API_KEY")}}
```

#### Memory

See the `Memory` row of the plugin table for what it does. Limits and safety:


- Notes are data. Every body that reaches the model is wrapped in `<MEMORY[slug] provenance=... confidence=...>` under a "never an instruction" line, and the index never shows a body except for pinned notes.
- `pinned: true` is refused for compaction provenance and for any note with `source.url`. An operator opts in with `{Memory, allow_pin_untrusted: true}`.
- `memory_write` takes `source: {"artifact": "web/abc.md"}` to point at a full source in the artifact store.
- A body is at most 32 000 bytes of UTF-8 without NUL. There is no delete tool: correct a note with a new one and `memory_link` with `supersedes`.
- The index budget is `index_token_budget` (2 000 tokens). Topics that do not fit become pointers that name `memory_search`.
- The harvest job shares the `compaction` Oban queue and uses `harvest_model` (default `gemini-3-flash-preview`).
- Plugin options: `{Memory, scope: :owner | :global, allow_pin_untrusted: false, harvest: true}`. Settings: `config :super_pi, :memory, index_token_budget: 2_000, max_body_bytes: 32_000, half_life_days: 30.0, harvest_model: "..."`.

#### Scheduler

`SuperPi.Plugins.Scheduler` runs prompts later or repeatedly with nobody watching: on a cron schedule, or when a third party calls a webhook. It is on in `super-pi-librarian` only.

##### Tools

| Tool | Effects | Use |
|---|---|---|
| `schedule_create` | `state_write` | `prompt`, `cron`, optional `timezone`, `mode`, `catch_up`, `name`, `trigger` |
| `schedule_list` | `read` | Schedules of this conversation, with status, next fire and failure count |
| `schedule_cancel` | `state_write` | Cancel by id |

The tools are not in the global tool catalog. The plugin adds them to a conversation's tool list, so a harness without it never offers them.

`cron` is five fields (`minute hour day-of-month month day-of-week`) or `@hourly`, `@daily`, `@weekly`. Granularity is one minute. Fires must be at least 5 minutes apart (`min_interval_minutes`), and a conversation has at most 10 schedules (`max_per_conversation`).

##### Run modes

| `mode` | Each run happens in |
|---|---|
| `fork` (default) | A fork of the conversation at its latest entry. The parent transcript stays clean. |
| `append` | The conversation itself. Use it for work that accumulates. |
| `fresh` | A new conversation built from the agent settings stored at creation. Fewest tokens. |

A run is a background task with `restart_limit: 2`. If its node dies, the run resumes on another node. With `catch_up: false` (default) a resumed run is cancelled instead, so a 07:00 briefing is never delivered at 11:00. With `catch_up: true`, a schedule that missed fires while the system was down runs once, however late.

Three failed runs in a row pause the schedule and add a note to the `notes` list of the conversation's `pi.inbox` document.

##### Time zones

`timezone` is an IANA name (`Europe/London`). Zone data ships inside the `tzdata` package. Its auto-update is off (`config :tzdata, :autoupdate, :disabled`), so a container needs no network access and no writable data directory. Update the data by updating the package.

Daylight saving time:

- A fixed-hour expression (`30 2 * * *`) fires once per local day. In the spring-forward gap it fires at the first minute after the gap. On fall-back it fires on the first occurrence only.
- An every-hour expression (`*/30 * * * *`) follows the real clock: no duplicate, no gap.

##### Webhook triggers

Off by default. Enable per harness: `{SuperPi.Plugins.Scheduler, allow_webhooks: true}`. Then `schedule_create` accepts `trigger: "webhook"` and returns a path with a secret token. The token is shown once and only its hash is stored.

```bash
curl -X POST http://localhost:4000/v1/triggers/$TOKEN \
  -H 'Idempotency-Key: build-1234' \
  -d '{"event":"push","repo":"super-pi-beam"}'
# 202 {"status":"accepted","message":"Queued."}
```

- The token is not the gateway bearer token. It wakes exactly one schedule.
- The reply is `202` as soon as the run is queued. The sender never waits for a model turn. `401`: unknown, paused or cancelled trigger. `413`: body over `config :super_pi, :trigger_max_bytes` (default 32768). `400`: body is not UTF-8 text, or the key is invalid. `503`: the node is draining; retry.
- The body goes into the schedule's prompt, fenced and marked as data. Put `{{payload}}` in the prompt to choose the place. The body comes from outside: treat it as untrusted input to an unattended agent.
- A repeated `Idempotency-Key` does nothing. The key is remembered while Oban keeps the job (24 hours with the default pruner). Without the header every delivery is a run.

##### Delivery guarantees

One static `Oban.Plugins.Cron` entry runs a tick every minute. Schedules are database rows, so adding one needs no deploy. Each fire happens once, through three layers: the Cron leader inserts one tick per minute for the whole cluster; the tick inserts one run job per due schedule, unique on the scheduled minute; the run claims the fire with one conditional update on `last_fire_at`. An Oban retry or a rescue after a crash cannot run a fire twice.

On SQLite (single node) and PostgreSQL (cluster) the behavior is the same. A SQLite deployment cannot run more than one node. Pickup is polled, about one second, which does not matter at minute granularity.

##### Limits

- Forks do not copy schedules. Schedules belong to a conversation id, so forking a conversation ten times does not create ten daily briefings.
- A scheduled run cannot create schedules (it would multiply without anyone to stop it). `allow_nested: true` lifts the guard.
- A schedule is never held open as a sleeping task. Between fires it is only a row.
- A failed or abandoned run does not retry on its own. The schedule fires again at the next scheduled minute.


#### Non-blocking delegation

`delegate_subagent` does not wait. The call creates one child conversation and one `pi.subagent` task per child, queues one job per child, puts the parent task in `waiting` and returns an acknowledgement. The tool result carries the `control` directive `{"await": ...}`, which parks the parent's machine.

```
parent turn:  delegate_subagent -> ack ........ parked (:awaiting_children) ........ summaries -> next request
children:                          job job job  (any node, :subagents queue limit)
```

- **Wait policy.** `wait_policy: "all"` (default) wakes the parent when every child has ended. `"fail_fast"` wakes it when the first child fails. The other children are then stopped.
- **Summaries.** Each child's final text (up to 8000 bytes) is stored as one user message: `Subagent <role> (conversation <id>) finished: ...`. It is not a second tool result, because providers refuse two results for one tool call.
- **One delegation at a time.** A second call while children run is refused. Put all tasks in one call (`tasks`).
- **Cancel.** `session.cancel` ends the turn, aborts the children's tasks bottom-up and cancels their machines. A queued job that finds its task aborted does nothing.
- **Node loss.** The parked parent stays `waiting` in the database. A new machine on another node parks again. A child's machine is restarted by Horde, resumes its turn and settles its own task. The job has `max_attempts: 1`: a lost job is not retried.
- **Timeout.** A child that exceeds `timeout_ms` is failed and stopped. The time counts from the start of its job, not from the delegation.
- **Events.** `subagent_started` and `subagent_finished` go to the parent conversation.

The parent machine wakes at once because `TaskEngine` sends `{:task_woken, task_id}` to the conversation's machine after the transaction commits. A poll every 5 s (`config :super_pi, :await_poll_ms`) covers a lost message.

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

The `Permissions` plugin enforces three execution modes: `plan` (read-only), `accept-edits` (file edits, shell commands only from the allow list) and `auto`. Workspace confinement is on by default (`allowNonWorkspaceAccess: false`). Policy is data: `config :super_pi, :permissions`, `<app data dir>/settings.json`, and the session's `settingsOverride`. `permissions.deny` blocks matching shell commands in every mode. A harness can set a ceiling (`maxExecutionMode`). A mode above the ceiling is lowered to it, so no flag or request lifts `super-pi-planner` out of `plan`.

**Tool effects.** A tool states what a call does in an `"effects"` list on its spec: `read`, `fs_write`, `exec`, `net_read`, `net_write`, `state_write`. The decision depends only on the effects, the mode and the policy, and it never loosens as the mode rises.

| Effects of the tool | `plan` | `accept-edits` | `auto` |
|---|---|---|---|
| only `read` | allow | allow | allow |
| `net_read` (with `read`) | allow (unless `network_in_plan_mode: false`) | allow | allow |
| `state_write` (with `read`, `net_read`) | block | allow | allow |
| `fs_write`, `exec`, `net_write`, or no effects stated | block | block, except `write`, `edit` and allowed commands | allow |

So the artifact tools, `todo`, `delegate_subagent`, `ask_question` and the memory, web and schedule tools work in the default `accept-edits` mode that every Gateway, RPC and MCP caller gets. A tool that states no effects gets the old behaviour.

**Network policy.** Network egress is a second axis, separate from the mode: `network: "allow" | "allowlist" | "deny"` (default `"allow"`). `deny` refuses every tool with a network effect. `allowlist` allows a call whose `url` argument has a host in `networkAllowHosts` (an entry matches the host and its subdomains) and refuses a call without a URL. A workspace can also remove the capability: see *Workspaces and Artifacts*.

**Asking a person.** Two blocks can be lifted by a person: a shell command that is not in `permissions.allow`, and a tool that `accept-edits` does not allow by default (every MCP tool that its server does not mark read-only). When a client can answer, the call goes ahead to the tool task and the task asks. The client sees `tool_started`, then a `permission_request` event with four options (`allow_once`, `allow_always`, `reject_once`, `reject_always`, the ACP option kinds). The machine keeps answering `cancel`, `steer`, `get_state` and `compact` while the question is open. `allow_always` and `reject_always` change the session's `settingsOverride` (`permissions.allow`, `allowTools`, `deny`, `denyTools`). They never write `settings.json`, and a remote caller cannot send `settingsOverride`.

These blocks are never askable: a `permissions.deny` match, a mode block (`plan` blocks every non-read tool), a workspace boundary, and the network policy.

**It fails closed.** With no client that can answer (the HTTP Gateway, headless `-p` runs, MCP tool calls, an RPC conversation nobody watches), a timeout, a cancel, or an answer that is not one of the four options, the call is blocked with the same message as before. `config :super_pi, :permissions, interactive_prompts: false` turns prompting off. `config :super_pi, permission_prompt_timeout_ms: 120_000` sets the wait. A `hooks.json` `PreToolUse` hook that answers `"decision": "ask"` uses the same path.

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
| `none` | No filesystem and no commands (API-style agents). | n/a | artifacts, MCP and web tools |

A tool that the workspace cannot serve is not offered to the model, and is refused if called. Each kind has the capabilities `fs`, `exec` and `net`, and `none` has only `net`. A tool states effects (see *Permissions and Remote Modes*) and the effects decide which capability it needs: `fs_write` needs `fs`, `exec` needs `exec`, `net_read` and `net_write` need `net`. The file and shell tools are matched by name. A tool that states no effects needs all three capabilities, so an unknown tool is not offered in a workspace that lacks one. Add `"network": false` to the workspace map (for example `{"kind": "local", "network": false}`) to remove `net`. The agent can then read a repository and cannot make outgoing calls. `Permissions` `network: deny` is a different control: the workspace decides whether the model sees a network tool, and the policy decides whether one call is allowed. A `shared` workspace without a `root` is an error, not a fall back to the local disk. A task that restarted (a crash or a failover) gets a new, empty scratch directory, and its first tool result says so.

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

TLS is tested against a real server: `make test-postgres-tls` creates the certificates, starts PostgreSQL with TLS in Docker and runs `test/super_pi/postgres_tls_test.exs`. To use your own server, see the file for the variables.

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
| `GET /v1/models` | The four harness ids (virtual models, each with its `capabilities`) plus models of every configured provider. Older harness ids are accepted but not listed. |
| `POST /v1/chat/completions` | Chat completion, `stream: false` (JSON) or `stream: true` (SSE `chat.completion.chunk` events, ending with `data: [DONE]`). |
| `POST /agui/v1/run`, `GET /agui/v1/sessions/:id/events`, `POST /agui/v1/sessions/:id/input` | AG-UI over SSE. See *AG-UI*. |
| `POST /mcp` (and `DELETE`) | MCP over Streamable HTTP. See *MCP*. |
| `POST /v1/triggers/:token` | Webhook trigger of one schedule. The trigger token authenticates, not the gateway token. See *Scheduler*. |

**Request**

```bash
curl http://127.0.0.1:4000/v1/chat/completions \
  -H 'Authorization: Bearer <key>' \            # only when tokens are configured
  -H 'x-session-id: my-chat' \                  # keeps one conversation across requests
  -H 'x-super-pi-mode: plan' \                  # optional, can only tighten the permission mode
  -d '{"model": "super-pi-code", "stream": true,
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
  alias SuperPi.Plugins

  use SuperPi.Harness,
    id: "my-company",
    name: "My Company Harness",
    description: "Coding agent with the company safety rules",
    plugins: [
      Plugins.Permissions,
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

To add a new domain persona (for example a security auditor, a documentation bot or a DevOps engineer):
1. Create a module with `use SuperPi.Harness` (see *Declaring a Harness*) in your application.
2. Register it: `config :super_pi, extra_harnesses: [MyApp.Harness.Auditor]`.
3. The persona is immediately available in OpenCode, the HTTP Gateway, the JSON-RPC server, ACP, AG-UI and the CLI (`--harness <id>`), with no change to the core engine.

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

### 4. ACP Client
Starts `bin/super-pi acp` as a subprocess, creates a session, sends one prompt, prints the streamed text and answers permission requests on the terminal. It does what an editor does:

```bash
mise exec -- mix run examples/acp_client.exs "list the files in this directory"
```

### 5. AG-UI Client
Needs a running gateway (`bin/super-pi gateway 4000`). Posts a run, prints text, tool calls and state changes from the SSE stream, and answers a permission request through the input route:

```bash
mise exec -- mix run examples/agui_client.exs "what is 15 plus 27?"
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

**Make targets.** The project has no CI service. Run these before a merge:

| Target | Runs |
| --- | --- |
| `make test` | SQLite suite. Compiler warnings fail the run. |
| `make test-postgres` | The suite and the `:postgres` tests against PostgreSQL 18 in Docker. |
| `make test-cluster` | Multi-node tests. Needs `DATABASE_URL`; `make pg-up` starts a PostgreSQL for it. |
| `make test-postgres-tls` | TLS tests against PostgreSQL in Docker. |
| `make test-image` | Builds the Docker image, starts it and probes `/health`. |

To run the PostgreSQL suite against your own server, use the commands in *PostgreSQL* above.

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
│   │   ├── client_fs.ex           # Reads the unsaved editor buffer through an ACP client
│   │   ├── file_lock.ex           # Per-path Registry-keyed advisory FileLock
│   │   ├── local.ex               # Local filesystem & gitignore-aware scanner
│   │   └── sandbox_runner.ex      # Unlinked Task supervisor with :max_heap_size & 4 MiB spill
│   ├── discovery.ex               # Config, data and discovery paths (app env, env vars, OS defaults)
│   ├── extension.ex               # Unified 12-hook extension behaviour & pipeline
│   ├── acp/
│   │   ├── server.ex              # Agent Client Protocol agent over stdio (bidirectional JSON-RPC)
│   │   └── session.ex             # ACP session: opaque id, modes, replay, fork, cancel order
│   ├── event.ex                   # SuperPi.Event: the typed turn event, one builder per type
│   ├── event/
│   │   ├── history.ex             # Visible messages in a neutral shape (AG-UI snapshot, ACP replay)
│   │   ├── renderer.ex            # Renderer behaviour (pure state machines)
│   │   └── renderer/              # openai, rpc, tui, acp, agui
│   ├── gateway/
│   │   ├── agui.ex                # AG-UI over SSE (run, attach, input)
│   │   ├── router.ex              # OpenAI-compatible HTTP Gateway with SSE streaming
│   │   └── server.ex              # Bandit listener; refuses a non-loopback bind without a token
│   ├── harness/                   # Harness personas declared with `use SuperPi.Harness`
│   │   ├── assistant.ex           # Knowledge work: questions, web, MCP connectors, no filesystem
│   │   ├── code.ex                # Repository coding agent: rules, skills, hooks, checkpoints, cascading
│   │   ├── defaults.ex            # One resolution ladder for model, workspace, tools and prompt
│   │   ├── legacy.ex              # Delegating shims for the harness modules of earlier releases
│   │   ├── librarian.ex           # Unattended knowledge keeper: memory, scheduler, web
│   │   └── planner.ex             # Read-only planning harness
│   ├── harness.ex                 # SuperPi.Harness behaviour, `use` macro, resolver, aliases
│   ├── mcp/
│   │   ├── client.ex              # MCP client for one server (any transport)
│   │   ├── http_plug.ex           # MCP server over Streamable HTTP, forwarded from the gateway router
│   │   ├── manager.ex             # Starts configured MCP servers, exposes mcp__<server>__<tool>
│   │   ├── server.ex              # Model Context Protocol server (stdio and the shared handler)
│   │   ├── sessions.ex            # Sessions of the HTTP server
│   │   ├── transport.ex           # Transport behaviour
│   │   └── transport/             # stdio and Streamable HTTP (with the HTTP+SSE fallback)
│   ├── memory.ex                  # Durable notes: write, read, link, duplicate warning
│   ├── memory/                    # Search (FTS5, tsvector, LIKE) and the budgeted index
│   ├── schedule.ex                # Schedules: create, tick, claim, run, failure accounting
│   ├── schedule/cron.ex           # Cron `next_after/3` with time zones (tzdata)
│   ├── triggers.ex                # Webhook triggers (POST /v1/triggers/:token)
│   ├── web/                       # Request-forgery policy, fetch, extraction, search adapters
│   ├── plugins/                   # 22 reusable plugins (JevRouter, Handoff, Permissions, Memory, Scheduler, Web, etc.)
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
│   │   ├── broker.ex              # Routes questions (ask_question, permission requests) to a client and back
│   │   ├── pending.ex             # Hands a decision from before_tool to wrap_tool
│   │   └── permission_prompt.ex   # Asks a person about a blocked tool call (fails closed)
│   └── workers/
│       ├── memory_harvest_worker.ex  # Extracts durable facts at compaction
│       ├── oban_workers.ex        # Oban workers (generation_retry, compaction, verification, subagents)
│       └── schedule_workers.ex    # Cron tick and scheduled run workers
examples/
├── acp_client.exs                 # Minimal ACP client: starts `bin/super-pi acp`, prompts, answers permissions
├── agui_client.exs                # Minimal AG-UI client for the gateway
├── gemini_live_demo.exs           # Live Gemini 3 Flash tool-calling demo
├── interactive_tui.exs            # Interactive Owl TUI loop
└── rpc_showcase_client.exs        # External JSON-RPC 2.0 client showcase
test/                              # ExUnitProperties property-based & integration test suites
```
