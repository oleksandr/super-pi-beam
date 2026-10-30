import Config

config :super_pi,
  ecto_repos: [SuperPi.Repo.SQLite],
  storage_backend: :sqlite,
  gateway_port: 4000,
  start_gateway: false

config :super_pi, SuperPi.Repo.SQLite,
  priv: "priv/repo",
  database: Path.expand("../priv/super_pi_#{config_env()}.db", __DIR__),
  # At least the sum of the Oban queue limits below, so a busy queue never starves the others.
  pool_size: 13,
  default_transaction_mode: :immediate,
  journal_mode: :wal,
  cache_size: -64000,
  temp_store: :memory,
  synchronous: :normal,
  busy_timeout: 30000

config :super_pi, SuperPi.Repo.Postgres,
  priv: "priv/repo"

config :super_pi, Oban,
  engine: Oban.Engines.Lite,
  repo: SuperPi.Repo.SQLite,
  queues: [
    generation_retry: 3,
    compaction: 2,
    verification: 2,
    subagents: 3,
    schedule_tick: 1,
    schedule_runs: 2
  ],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 86_400},
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(30)},
    # One static entry. User schedules are rows in `schedules`; the tick worker fires the due ones.
    {Oban.Plugins.Cron, crontab: [{"* * * * *", SuperPi.Workers.ScheduleTickWorker}]}
  ]

# IANA zone data for schedules comes bundled with `tzdata`. Its default polls daily and downloads
# new releases at run time, which needs egress and a writable data directory.
config :elixir, :time_zone_database, Tzdata.TimeZoneDatabase
config :tzdata, :autoupdate, :disabled

# Every log line from a conversation process carries its conversation and task id.
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:conversation_id, :task_id]

# OpenTelemetry. No exporter by default; set OTEL_EXPORTER_OTLP_ENDPOINT to export (see runtime.exs).
config :opentelemetry,
  resource: [service: [name: "super-pi-beam"]],
  span_processor: :batch,
  traces_exporter: :none

import_config "#{config_env()}.exs"
