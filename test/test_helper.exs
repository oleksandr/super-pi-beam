# :postgres needs a database: `SUPER_PI_STORAGE_BACKEND=postgres DATABASE_URL=... mix test --include postgres`.
# :cluster starts three Erlang nodes against PostgreSQL: `... mix test --only cluster`.
# :live calls real provider APIs: `GEMINI_API_KEY=... mix test --include live`.
ExUnit.start(exclude: [:postgres, :live, :cluster])
Ecto.Adapters.SQL.Sandbox.mode(SuperPi.Repo.active_repo(), :manual)
