defmodule SuperPi.Properties.MigrationTest do
  @moduledoc """
  Property of the durable schema migration: any sequence of `up` and `down` steps, ended by a
  full `up`, leaves the schema of a single `up`.

  The SQLite variant runs on a temporary database. The PostgreSQL variant runs only when
  `SUPER_PI_MIGRATION_TEST_URL` is set (`mix test --only postgres`). It checks the circular
  foreign keys between `conversations`, `entries` and `tasks`, which SQLite does not enforce
  at creation.

  The variant migrates the database down, so point the variable at a scratch database that
  no other test uses. It is not `DATABASE_URL` on purpose: the suite's own database would
  lose its schema.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  @moduletag :migration
  @path Path.expand("../../../priv/repo/migrations", __DIR__)

  # Schema as comparable data: table names, columns and indexes.
  defp schema(repo, :sqlite) do
    {:ok, %{rows: tables}} =
      repo.query(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name <> 'schema_migrations' ORDER BY name"
      )

    for [table] <- tables do
      {:ok, %{rows: cols}} =
        repo.query(
          "SELECT name, type, \"notnull\" FROM pragma_table_info('#{table}') ORDER BY name"
        )

      {:ok, %{rows: idx}} =
        repo.query(
          "SELECT name FROM pragma_index_list('#{table}') WHERE origin = 'c' ORDER BY name"
        )

      {table, cols, idx}
    end ++ [{:triggers, sqlite_triggers(repo)}]
  end

  defp schema(repo, :postgres) do
    {:ok, %{rows: cols}} =
      repo.query(
        "SELECT table_name, column_name, data_type, is_nullable FROM information_schema.columns WHERE table_schema = current_schema() AND table_name <> 'schema_migrations' ORDER BY 1, 2"
      )

    {:ok, %{rows: idx}} =
      repo.query(
        "SELECT tablename, indexname FROM pg_indexes WHERE schemaname = current_schema() AND tablename <> 'schema_migrations' ORDER BY 1, 2"
      )

    {cols, idx}
  end

  defp sqlite_triggers(repo) do
    {:ok, %{rows: rows}} =
      repo.query("SELECT name FROM sqlite_master WHERE type = 'trigger' ORDER BY name")

    rows
  end

  # `Ecto.Migrator` runs migrations in the repo that `dynamic_repo` names, here the temporary one.
  defp migrate(repo, direction) do
    Ecto.Migrator.run(repo, @path, direction,
      all: true,
      dynamic_repo: repo.get_dynamic_repo(),
      log: false
    )
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

      {:ok, pid} =
        SuperPi.Repo.SQLite.start_link(
          name: nil,
          database: db,
          pool_size: 1,
          pool: DBConnection.ConnectionPool
        )

      SuperPi.Repo.SQLite.put_dynamic_repo(pid)

      try do
        migrate(SuperPi.Repo.SQLite, :up)
        baseline = schema(SuperPi.Repo.SQLite, :sqlite)
        assert length(baseline) > 1

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
    url =
      System.get_env("SUPER_PI_MIGRATION_TEST_URL") ||
        flunk("SUPER_PI_MIGRATION_TEST_URL is not set")

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

  # --- The memories migration branches on the adapter ---

  defp with_tmp_sqlite(fun) do
    tmp = Path.join(System.tmp_dir!(), "mig_mem_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    {:ok, pid} =
      SuperPi.Repo.SQLite.start_link(
        name: nil,
        database: Path.join(tmp, "m.db"),
        pool_size: 1,
        pool: DBConnection.ConnectionPool
      )

    SuperPi.Repo.SQLite.put_dynamic_repo(pid)

    try do
      fun.(SuperPi.Repo.SQLite)
    after
      SuperPi.Repo.SQLite.put_dynamic_repo(SuperPi.Repo.SQLite)
      Supervisor.stop(pid)
      File.rm_rf!(tmp)
    end
  end

  defp insert_memory(repo, id, title, topics, body) do
    repo.query!(
      "INSERT INTO memories (id, slug, title, topics, body, created_seq, updated_seq, inserted_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, 1, 1, '2026-01-01', '2026-01-01')",
      [id, "s#{id}", title, topics, body]
    )
  end

  defp fts_ids(repo, query) do
    {:ok, %{rows: rows}} =
      repo.query("SELECT rowid FROM memories_fts WHERE memories_fts MATCH ?1 ORDER BY rowid", [
        query
      ])

    List.flatten(rows)
  end

  test "memories migration on SQLite: triggers keep FTS5 in step, down removes everything, up restores it" do
    with_tmp_sqlite(fn repo ->
      migrate(repo, :up)
      before_memories = schema(repo, :sqlite)

      insert_memory(repo, 1, "Alpha title", "ops", "first body")
      insert_memory(repo, 2, "Beta title", "dev", "second body")
      assert fts_ids(repo, "alpha") == [1]
      assert fts_ids(repo, "body") == [1, 2]

      repo.query!("UPDATE memories SET title = 'Gamma title' WHERE id = 1")
      assert fts_ids(repo, "alpha") == []
      assert fts_ids(repo, "gamma") == [1]

      # An update of other columns leaves the index alone.
      repo.query!("UPDATE memories SET pinned = 1 WHERE id = 1")
      assert fts_ids(repo, "gamma") == [1]

      repo.query!("DELETE FROM memories WHERE id = 2")
      assert fts_ids(repo, "beta") == []

      assert {:ok, %{rows: [[1]]}} = repo.query("SELECT count(*) FROM memories")

      Ecto.Migrator.run(repo, @path, :down,
        step: 1,
        dynamic_repo: repo.get_dynamic_repo(),
        log: false
      )

      names =
        for {name, _, _} <-
              Enum.filter(schema(repo, :sqlite), &(is_tuple(&1) and tuple_size(&1) == 3)),
            do: name

      refute Enum.any?(names, &String.starts_with?(&1, "memor"))
      assert sqlite_triggers(repo) == []
      assert "conversations" in names

      migrate(repo, :up)

      assert Enum.map(schema(repo, :sqlite), &elem(&1, 0)) ==
               Enum.map(before_memories, &elem(&1, 0))

      assert fts_ids(repo, "gamma") == []
    end)
  end

  @tag :postgres
  test "memories migration on PostgreSQL: generated tsvector with GIN, and a working down" do
    url =
      System.get_env("SUPER_PI_MIGRATION_TEST_URL") ||
        flunk("SUPER_PI_MIGRATION_TEST_URL is not set")

    {:ok, pid} = SuperPi.Repo.Postgres.start_link(name: nil, url: url, pool_size: 2)
    SuperPi.Repo.Postgres.put_dynamic_repo(pid)
    repo = SuperPi.Repo.Postgres

    try do
      migrate(repo, :down)
      migrate(repo, :up)

      repo.query!(
        "INSERT INTO memories (slug, title, topics, body, created_seq, updated_seq, inserted_at, updated_at) VALUES ('a', 'Alpha title', 'ops', 'first body', 1, 1, now(), now())"
      )

      assert {:ok, %{rows: [[1]]}} =
               repo.query(
                 "SELECT count(*) FROM memories WHERE search @@ websearch_to_tsquery('simple', 'alpha or zebra')"
               )

      assert {:ok, %{rows: [[0]]}} =
               repo.query(
                 "SELECT count(*) FROM memories WHERE search @@ websearch_to_tsquery('simple', 'zebra')"
               )

      repo.query!("UPDATE memories SET title = 'Gamma title'")

      assert {:ok, %{rows: [[1]]}} =
               repo.query(
                 "SELECT count(*) FROM memories WHERE search @@ websearch_to_tsquery('simple', 'gamma')"
               )

      assert {:ok, %{rows: [["memories_search_idx"]]}} =
               repo.query(
                 "SELECT indexname FROM pg_indexes WHERE indexname = 'memories_search_idx'"
               )

      Ecto.Migrator.run(repo, @path, :down,
        step: 1,
        dynamic_repo: repo.get_dynamic_repo(),
        log: false
      )

      assert {:ok, %{rows: []}} =
               repo.query(
                 "SELECT 1 FROM information_schema.tables WHERE table_name IN ('memories', 'memory_links')"
               )

      migrate(repo, :down)
    after
      SuperPi.Repo.Postgres.put_dynamic_repo(SuperPi.Repo.Postgres)
      Supervisor.stop(pid)
    end
  end
end
