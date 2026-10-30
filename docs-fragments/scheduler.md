## Scheduler

`SuperPi.Plugins.Scheduler` runs prompts later or repeatedly with nobody watching: on a cron schedule, or when a third party calls a webhook. It is on in `super-pi-librarian` only.

### Tools

| Tool | Effects | Use |
|---|---|---|
| `schedule_create` | `state_write` | `prompt`, `cron`, optional `timezone`, `mode`, `catch_up`, `name`, `trigger` |
| `schedule_list` | `read` | Schedules of this conversation, with status, next fire and failure count |
| `schedule_cancel` | `state_write` | Cancel by id |

The tools are not in the global tool catalog. The plugin adds them to a conversation's tool list, so a harness without it never offers them.

`cron` is five fields (`minute hour day-of-month month day-of-week`) or `@hourly`, `@daily`, `@weekly`. Granularity is one minute. Fires must be at least 5 minutes apart (`min_interval_minutes`), and a conversation has at most 10 schedules (`max_per_conversation`).

### Run modes

| `mode` | Each run happens in |
|---|---|
| `fork` (default) | A fork of the conversation at its latest entry. The parent transcript stays clean. |
| `append` | The conversation itself. Use it for work that accumulates. |
| `fresh` | A new conversation built from the agent settings stored at creation. Fewest tokens. |

A run is a background task with `restart_limit: 2`. If its node dies, the run resumes on another node. With `catch_up: false` (default) a resumed run is cancelled instead, so a 07:00 briefing is never delivered at 11:00. With `catch_up: true`, a schedule that missed fires while the system was down runs once, however late.

Three failed runs in a row pause the schedule and add a note to the `notes` list of the conversation's `pi.inbox` document.

### Time zones

`timezone` is an IANA name (`Europe/London`). Zone data ships inside the `tzdata` package. Its auto-update is off (`config :tzdata, :autoupdate, :disabled`), so a container needs no network access and no writable data directory. Update the data by updating the package.

Daylight saving time:

- A fixed-hour expression (`30 2 * * *`) fires once per local day. In the spring-forward gap it fires at the first minute after the gap. On fall-back it fires on the first occurrence only.
- An every-hour expression (`*/30 * * * *`) follows the real clock: no duplicate, no gap.

### Webhook triggers

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

### Delivery guarantees

One static `Oban.Plugins.Cron` entry runs a tick every minute. Schedules are database rows, so adding one needs no deploy. Each fire happens once, through three layers: the Cron leader inserts one tick per minute for the whole cluster; the tick inserts one run job per due schedule, unique on the scheduled minute; the run claims the fire with one conditional update on `last_fire_at`. An Oban retry or a rescue after a crash cannot run a fire twice.

On SQLite (single node) and PostgreSQL (cluster) the behavior is the same. A SQLite deployment cannot run more than one node. Pickup is polled, about one second, which does not matter at minute granularity.

### Limits

- Forks do not copy schedules. Schedules belong to a conversation id, so forking a conversation ten times does not create ten daily briefings.
- A scheduled run cannot create schedules (it would multiply without anyone to stop it). `allow_nested: true` lifts the guard.
- A schedule is never held open as a sleeping task. Between fires it is only a row.
- A failed or abandoned run does not retry on its own. The schedule fires again at the next scheduled minute.
