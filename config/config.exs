import Config

config :super_pi,
  ecto_repos: [SuperPi.Repo.SQLite],
  storage_backend: :sqlite,
  gateway_port: 4000,
  start_gateway: false

config :super_pi, SuperPi.Repo.SQLite,
  priv: "priv/repo",
  database: Path.expand("../priv/super_pi_#{config_env()}.db", __DIR__),
  pool_size: 5,
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
    generation_retry: 20,
    compaction: 5,
    verification: 10,
    subagents: 20
  ],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 86_400},
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(30)}
  ]

import_config "#{config_env()}.exs"
