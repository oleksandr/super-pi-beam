import Config

config :super_pi, SuperPi.Repo.SQLite,
  database: Path.expand("../priv/super_pi_test.db", __DIR__),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10,
  journal_mode: :wal,
  busy_timeout: 30000

config :super_pi, Oban, testing: :manual
config :super_pi, :mock_llm, true
# The test alias migrates before the suite; the sandbox must not race a second run.
config :super_pi, auto_migrate: false
# Tests that need MCP servers start them explicitly.
config :super_pi, mcp_clients: false
# The periodic flusher runs outside the Ecto sandbox, so in tests it would only log
# ownership errors. Tests that need a flush call `DeferredFlusher.flush_now!/0`.
config :super_pi, deferred_flush_interval_ms: 3_600_000
# Spans go to a test process (`SuperPi.TelemetryTest`); nothing is exported.
config :opentelemetry, span_processor: :simple, traces_exporter: :none

config :logger, level: :warning

# Keep discovery and transcript output out of the real user directories.
test_tmp = Path.join(System.tmp_dir!(), "super_pi_test")
config :super_pi, app_data_dir: Path.join(test_tmp, "data")
config :super_pi, global_config_dir: Path.join(test_tmp, "config")
