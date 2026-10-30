defmodule SuperPi.Memory.Search.FTS5 do
  @moduledoc """
  SQLite backend: the `memories_fts` FTS5 table, ranked by `bm25()` (title 10, topics 5, body 1).

  The table is an external-content index that triggers keep in step with `memories`, so a note is
  searchable in the transaction that wrote it. Words reach `MATCH` as quoted terms joined by `OR`.
  Limit: the `unicode61` tokenizer splits on anything that is not a letter or digit, so it does not
  segment languages written without spaces; a CJK note matches as one long token.
  """

  @behaviour SuperPi.Memory.Search

  alias SuperPi.Memory.Search

  @impl true
  def name, do: "fts5"

  @impl true
  def candidates({kind, id}, words, topic, limit) do
    match = Enum.map_join(words, " OR ", &~s("#{&1}"))

    sql = """
    SELECT m.id, -bm25(memories_fts, 10.0, 5.0, 1.0)
    FROM memories_fts JOIN memories m ON m.id = memories_fts.rowid
    WHERE memories_fts MATCH ?1 AND m.scope_kind = ?2 AND m.scope_id = ?3
      AND (' ' || m.topics || ' ') LIKE ?4 ESCAPE '\\'
    ORDER BY bm25(memories_fts, 10.0, 5.0, 1.0)
    LIMIT ?5
    """

    case SuperPi.Repo.active_repo().query(sql, [
           match,
           kind,
           id,
           Search.topic_pattern(topic),
           limit
         ]) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, fn [id, rank] -> {id, rank / 1} end)}
      {:error, reason} -> {:error, reason}
    end
  end
end
