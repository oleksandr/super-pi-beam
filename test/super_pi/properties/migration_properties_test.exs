defmodule SuperPi.Properties.MigrationTest do
  @moduledoc """
  Property of the durable schema migration: any sequence of `up` and `down` steps, ended by a
  full `up`, leaves the schema of a single `up`.

  The SQLite variant runs on a temporary database. The PostgreSQL variant runs only when
  `DATABASE_URL` is set (`mix test --include postgres`). It checks the circular foreign keys
  between `conversations`, `entries` and `tasks`, which SQLite does not enforce at creation.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  @moduletag :migration
  @path Path.expand("../../../priv/repo/migrations", __DIR__)

  # Schema as comparable data: table names, columns and indexes.
  defp schema(repo, :sqlite) do
    {:ok, %{rows: tables}} = repo.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name <> 'schema_migrations' ORDER BY name")

    for [table] <- tables do
      {:ok, %{rows: cols}} = repo.query("SELECT name, type, \"notnull\" FROM pragma_table_info('#{table}') ORDER BY name")
      {:ok, %{rows: idx}} = repo.query("SELECT name FROM pragma_index_list('#{table}') WHERE origin = 'c' ORDER BY name")
      {table, cols, idx}
    end
  end

  defp schema(repo, :postgres) do
    {:ok, %{rows: cols}} =
      repo.query("SELECT table_name, column_name, data_type, is_nullable FROM information_schema.columns WHERE table_schema = current_schema() AND table_name <> 'schema_migrations' ORDER BY 1, 2")

    {:ok, %{rows: idx}} =
      repo.query("SELECT tablename, indexname FROM pg_indexes WHERE schemaname = current_schema() AND tablename <> 'schema_migrations' ORDER BY 1, 2")

    {cols, idx}
  end

  # `Ecto.Migrator` runs migrations in the repo that `dynamic_repo` names, here the temporary one.
  defp migrate(repo, direction) do
    Ecto.Migrator.run(repo, @path, direction, all: true, dynamic_repo: repo.get_dynamic_repo(), log: false)
  end

  defp step(repo, :up), do: migrate(repo, :up)
  defp step(repo, :down), do: migrate(repo, :down)

  defp up_down_sequences, do: list_of(member_of([:up, :down]), max_length: 6)

  property "any up and down sequence ends in the schema of a single up (SQLite)" do
    tmp = Path.join(System.tmp_dir!(), "mig_props_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    check all(seq <- up_down_sequences(), max_runs: 10) do
      db = Path.join(tmp, "m_#{System.unique_integer([:positive])}.db")
      {:ok, pid} = SuperPi.Repo.SQLite.start_link(name: nil, database: db, pool_size: 1, pool: DBConnection.ConnectionPool)
      SuperPi.Repo.SQLite.put_dynamic_repo(pid)

      try do
        migrate(SuperPi.Repo.SQLite, :up)
        baseline = schema(SuperPi.Repo.SQLite, :sqlite)
        assert baseline != []

        Enum.each(seq, &step(SuperPi.Repo.SQLite, &1))
        migrate(SuperPi.Repo.SQLite, :up)

        assert schema(SuperPi.Repo.SQLite, :sqlite) == baseline
      after
        SuperPi.Repo.SQLite.put_dynamic_repo(SuperPi.Repo.SQLite)
        Supervisor.stop(pid)
      end
    end
  end

  @tag :postgres
  property "any up and down sequence ends in the schema of a single up (PostgreSQL)" do
    url = System.get_env("DATABASE_URL")
    {:ok, pid} = SuperPi.Repo.Postgres.start_link(name: nil, url: url, pool_size: 2)
    SuperPi.Repo.Postgres.put_dynamic_repo(pid)

    try do
      migrate(SuperPi.Repo.Postgres, :down)
      migrate(SuperPi.Repo.Postgres, :up)
      baseline = schema(SuperPi.Repo.Postgres, :postgres)

      check all(seq <- up_down_sequences(), max_runs: 8) do
        Enum.each(seq, &step(SuperPi.Repo.Postgres, &1))
        migrate(SuperPi.Repo.Postgres, :up)
        assert schema(SuperPi.Repo.Postgres, :postgres) == baseline
      end

      migrate(SuperPi.Repo.Postgres, :down)
    after
      SuperPi.Repo.Postgres.put_dynamic_repo(SuperPi.Repo.Postgres)
      Supervisor.stop(pid)
    end
  end
end
