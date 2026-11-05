# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-11-05

### Added
- **Unified Always-Durable Engine (`SuperPi.Durable`)**:
  - SQLite WAL mode and PostgreSQL backend support with automatic schema migrations.
  - Core persistence tables: conversations, entries, tasks, submissions, documents, and revisions with monotonic sequencing.
  - Scoped documents (`pi.agent`, `pi.provider`, `pi.live`, `pi.inbox`, `pi.usage`) with JSONPatch operational deltas.
  - `DeferredFlusher` with ETS staging and lazy database flush.
- **Two-Tier State Machines & Queue Execution**:
  - `SuperPi.Conversation.Machine`: `:gen_statem` turn coordinator with postponement queueing and mid-batch steer preemption.
  - `SuperPi.Durable.TaskEngine`: `Fsmx` atomic task lifecycle transitions.
  - Persistent Oban background queues for retry, compaction, verification, subagents, and schedules.
- **Context Derivation**:
  - Normative 10-rule context derivation with fork ancestry walking, non-destructive editing (`omit`, `replace`), and prompt cache warming.
- **4-Layer Crash-Immune Tool Execution**:
  - Layer 1: Unlinked supervisor tasks with heap size limits.
  - Layer 2: Streaming OS process execution via Exile.
  - Layer 3: Advisory file locking per `{env_id, canonical_path}`.
  - Layer 4: Standard built-in tools (`read`, `write`, `edit`, `bash`, `grep`, `find`, `ls`, `tool_search`) with structured output channels.
- **Multi-Interface Support**:
  - Terminal interactive ANSI UI built on `Owl`.
  - JSON-RPC 2.0 server with `K = 2` ack-clocked backpressure.
  - OpenAI-compatible SSE gateway, ACP (Agent Client Protocol), and AG-UI renderers.
- **Package Release**:
  - Initial publication of `:super_pi` on [Hex.pm](https://hex.pm/packages/super_pi).
