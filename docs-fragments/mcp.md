## MCP

Super-Pi-BEAM is an MCP client and an MCP server. Both sides speak the protocol versions `2025-06-18`, `2025-03-26` and `2024-11-05`. The server does not support `2026-07-28`.

### Use MCP servers (client)

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

### Use Super-Pi as an MCP server

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
