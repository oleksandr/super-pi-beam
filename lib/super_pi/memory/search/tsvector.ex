defmodule SuperPi.Memory.Search.Tsvector do
  @moduledoc """
  PostgreSQL backend: the generated `memories.search` `tsvector` column under a GIN index, ranked by
  `ts_rank_cd` (title weight A, topics B, body C).

  The query goes through `websearch_to_tsquery('simple', ...)`, which never raises on user text.
  Words are joined by `or`, so a note matches on any word. The word `or` itself is dropped because
  the parser reads it as the operator. The `simple` configuration does not stem and does not fold
  accents, so `deploys` does not match `deploy` and `cafe` does not match `café`.
  """

  @behaviour SuperPi.Memory.Search

  alias SuperPi.Memory.Search

  @impl true
  def name, do: "tsvector"

  @impl true
  def candidates({kind, id}, words, topic, limit) do
    query = words |> Enum.reject(&(&1 == "or")) |> Enum.join(" or ")

    sql = """
    SELECT m.id, ts_rank_cd(m.search, q)::float8
    FROM memories m, websearch_to_tsquery('simple', $1::text) q
    WHERE m.search @@ q AND m.scope_kind = $2 AND m.scope_id = $3
      AND (' ' || m.topics || ' ') LIKE $4 ESCAPE '\\'
    ORDER BY 2 DESC
    LIMIT $5
    """

    case SuperPi.Repo.active_repo().query(sql, [
           query,
           kind,
           id,
           Search.topic_pattern(topic),
           limit
         ]) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, fn [id, rank] -> {id, rank} end)}
      {:error, reason} -> {:error, reason}
    end
  end
end
