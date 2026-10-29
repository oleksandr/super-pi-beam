import Config

case System.get_env("SUPER_PI_STORAGE_BACKEND") do
  "postgres" ->
    config :super_pi, storage_backend: :postgres

    config :super_pi, SuperPi.Repo.Postgres,
      url: System.get_env("DATABASE_URL") || "ecto://postgres:postgres@localhost/super_pi_dev",
      pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")

    config :super_pi, Oban,
      engine: Oban.Engines.Basic,
      repo: SuperPi.Repo.Postgres

  _ ->
    if db_path = System.get_env("SUPER_PI_SQLITE_PATH") do
      config :super_pi, SuperPi.Repo.SQLite, database: db_path
    end
end
