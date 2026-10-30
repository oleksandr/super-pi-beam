<!-- README fragment: replaces the `Subagent` row of the plugin table and adds the section below it. -->

| **`Subagent`** | `SuperPi.Plugins.Subagent` | **`delegate_subagent` tool**: starts child conversations and returns at once. Each child runs as an Oban job (`SubagentWorker`, queue `:subagents`) on any node. The parent parks in `:awaiting_children` and still answers `cancel`, `get_state` and `compact`. When the children end, their summaries arrive as separate messages and the turn goes on. Roles `scout`, `planner`, `reviewer`, `researcher` are read-only (plan mode). A `worker` inherits the parent's mode and settings and never gains permission. A child cannot delegate further (`subagent_max_depth`, default 1), cannot ask the user, and ends at `subagent_timeout_ms` (default 120 s). `session.cancel` aborts the whole subtree. |

### Non-blocking delegation

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
