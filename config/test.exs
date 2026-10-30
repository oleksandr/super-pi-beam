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

# Keep discovery and transcript output out of the real user directories.
test_tmp = Path.join(System.tmp_dir!(), "super_pi_test")
config :super_pi, app_data_dir: Path.join(test_tmp, "data")
config :super_pi, global_config_dir: Path.join(test_tmp, "config")
