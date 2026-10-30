# PostgreSQL tests need a database: `DATABASE_URL=... mix test --include postgres`.
ExUnit.start(exclude: [:postgres])
Ecto.Adapters.SQL.Sandbox.mode(SuperPi.Repo.SQLite, :manual)
