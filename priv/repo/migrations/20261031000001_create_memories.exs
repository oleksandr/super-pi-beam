defmodule SuperPi.Repo.Migrations.CreateMemories do
  use Ecto.Migration

  # Durable notes of the Memory plugin. This is the first migration that branches on the adapter,
  # because the lexical index is not portable: SQLite keeps an FTS5 table in step through triggers,
  # PostgreSQL keeps a generated `tsvector` column under a GIN index. Both branches have a `down`.
  #
  # `origin_conversation_id` is not a foreign key on purpose: deleting a conversation must never
  # delete knowledge.

  def up do
    create table(:memories) do
      add :scope_kind, :string, null: false, default: "owner"
      add :scope_id, :string, null: false, default: ""
      add :slug, :string, size: 64, null: false
      add :title, :text, null: false
      add :body, :text, null: false
      # Space-separated normalized topic words, so one text column feeds the index.
      add :topics, :text, null: false, default: ""
      add :provenance, :string, null: false, default: "agent"
      add :confidence, :float, null: false, default: 0.7
      add :source, :map, null: false, default: %{}
      add :pinned, :boolean, null: false, default: false
      add :superseded_by_id, references(:memories, on_delete: :nilify_all)
      add :created_seq, :bigint, null: false
      add :updated_seq, :bigint, null: false
      add :origin_conversation_id, :bigint
      add :origin_entry_seq, :bigint

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:memories, [:scope_kind, :scope_id, :slug])
    create index(:memories, [:scope_kind, :scope_id, :updated_seq])

    create table(:memory_links) do
      add :from_id, references(:memories, on_delete: :delete_all), null: false
      add :to_id, references(:memories, on_delete: :delete_all), null: false
      add :rel, :string, null: false
      add :created_seq, :bigint, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:memory_links, [:from_id, :to_id, :rel])
    create index(:memory_links, [:to_id])

    case adapter() do
      :sqlite -> up_sqlite()
      :postgres -> up_postgres()
    end
  end

  def down do
    case adapter() do
      :sqlite -> down_sqlite()
      :postgres -> down_postgres()
    end

    drop table(:memory_links)
    drop table(:memories)
  end

  # --- SQLite: external-content FTS5 table kept in step by triggers ---

  defp up_sqlite do
    execute """
    CREATE VIRTUAL TABLE memories_fts USING fts5(
      title, topics, body,
      content='memories', content_rowid='id',
      tokenize='unicode61 remove_diacritics 2'
    )
    """

    execute """
    CREATE TRIGGER memories_fts_ai AFTER INSERT ON memories BEGIN
      INSERT INTO memories_fts(rowid, title, topics, body) VALUES (new.id, new.title, new.topics, new.body);
    END
    """

    execute """
    CREATE TRIGGER memories_fts_ad AFTER DELETE ON memories BEGIN
      INSERT INTO memories_fts(memories_fts, rowid, title, topics, body) VALUES ('delete', old.id, old.title, old.topics, old.body);
    END
    """

    execute """
    CREATE TRIGGER memories_fts_au AFTER UPDATE OF title, topics, body ON memories BEGIN
      INSERT INTO memories_fts(memories_fts, rowid, title, topics, body) VALUES ('delete', old.id, old.title, old.topics, old.body);
      INSERT INTO memories_fts(rowid, title, topics, body) VALUES (new.id, new.title, new.topics, new.body);
    END
    """
  end

  defp down_sqlite do
    execute "DROP TRIGGER IF EXISTS memories_fts_au"
    execute "DROP TRIGGER IF EXISTS memories_fts_ad"
    execute "DROP TRIGGER IF EXISTS memories_fts_ai"
    execute "DROP TABLE IF EXISTS memories_fts"
  end

  # --- PostgreSQL: generated tsvector with GIN ---

  # The `simple` configuration does no stemming and no stop words, so it indexes any language the
  # same way and the stored column is deterministic.
  defp up_postgres do
    execute """
    ALTER TABLE memories ADD COLUMN search tsvector GENERATED ALWAYS AS (
      setweight(to_tsvector('simple', coalesce(title, '')), 'A') ||
      setweight(to_tsvector('simple', coalesce(topics, '')), 'B') ||
      setweight(to_tsvector('simple', coalesce(body, '')), 'C')
    ) STORED
    """

    execute "CREATE INDEX memories_search_idx ON memories USING GIN (search)"
  end

  defp down_postgres do
    execute "DROP INDEX IF EXISTS memories_search_idx"
    execute "ALTER TABLE memories DROP COLUMN IF EXISTS search"
  end

  defp adapter do
    case repo().__adapter__() do
      Ecto.Adapters.SQLite3 -> :sqlite
      Ecto.Adapters.Postgres -> :postgres
      other -> raise "the memories migration supports SQLite and PostgreSQL, not #{inspect(other)}"
    end
  end
end
