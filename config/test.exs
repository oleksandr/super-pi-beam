import Config

config :super_pi, SuperPi.Repo.SQLite,
  database: Path.expand("../priv/super_pi_test.db", __DIR__),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10,
  journal_mode: :wal,
  busy_timeout: 30000

config :super_pi, Oban, testing: :manual
config :super_pi, :mock_llm, true

config :logger, level: :warning
