import Config

config :super_pi, SuperPi.Repo.SQLite,
  database: Path.expand("../priv/super_pi_test.db", __DIR__),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10,
  journal_mode: :wal,
  busy_timeout: 5000

config :super_pi, Oban, testing: :manual

config :logger, level: :warning
