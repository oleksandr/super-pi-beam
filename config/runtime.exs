import Config

case System.get_env("SUPER_PI_STORAGE_BACKEND") do
  "postgres" ->
    database_url =
      System.get_env("DATABASE_URL") ||
        raise "DATABASE_URL environment variable is required when SUPER_PI_STORAGE_BACKEND=postgres"

    config :super_pi,
      storage_backend: :postgres,
      ecto_repos: [SuperPi.Repo.Postgres]

    config :super_pi, SuperPi.Repo.Postgres,
      url: database_url,
      pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")

    # `SUPER_PI_STORAGE_BACKEND=postgres mix test` runs the suite on PostgreSQL.
    if config_env() == :test do
      config :super_pi, SuperPi.Repo.Postgres, pool: Ecto.Adapters.SQL.Sandbox
      config :super_pi, Oban, testing: :manual
    end

    config :super_pi, Oban,
      engine: Oban.Engines.Basic,
      repo: SuperPi.Repo.Postgres

  _ ->
    if db_path = System.get_env("SUPER_PI_SQLITE_PATH") do
      config :super_pi, SuperPi.Repo.SQLite, database: db_path
    end
end
