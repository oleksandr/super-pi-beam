defmodule SuperPi.Memory.Search do
  @moduledoc """
  Lexical search over notes, without a vector store.

  A backend finds candidates and a raw rank. This module then scores them the same way for every
  backend, so ranking does not depend on which one answered.

  ## Backends

  The backend follows the storage backend, and `details` of `memory_search` names the one that
  answered:

  | Storage | Backend | Rank |
  |---|---|---|
  | SQLite | `SuperPi.Memory.Search.FTS5` (`fts5`) | `bm25()` with title 10, topics 5, body 1 |
  | PostgreSQL | `SuperPi.Memory.Search.Tsvector` (`tsvector`) | `ts_rank_cd` on the generated column |
  | any other, and tests that ask for it | `SuperPi.Memory.Search.Like` (`like`) | weighted word hits |

  A backend that errors (a missing index table, say) does not fail the search: it falls back to
  `Like` and the result says `degraded: true`. A search with no words and only a topic filter uses
  `Like` by design and is not degraded. Set `config :super_pi, :memory, search: Module` to force a backend.

  The query is split into words. A note matches when it has any word, and a note with more words
  ranks higher. FTS5 and `tsvector` get quoted words, never raw query syntax, so a model cannot
  break the query.

  ## Score

      score = text + recency_weight * 0.5^(age_days / half_life_days) + (pinned ? pinned_bonus : 0) - superseded penalty

  `text` is the raw rank divided by the best raw rank of the candidates, in (0, 1]. BM25 is near
  zero on a tiny corpus (every word is in most notes), and relative rank keeps the order. A
  superseded note takes a penalty of 10, which is above any other term. Then `apply_supersession/1`
  clamps a superseded note below its superseder when both are in the result, so a corrected fact
  always outranks the fact it corrected, also along a chain.
  """

  import Ecto.Query

  alias SuperPi.Durable.Schemas.Memory
  alias SuperPi.Memory, as: M
  alias SuperPi.Memory.Search.{FTS5, Like, Tsvector}
  alias SuperPi.Repo

  @doc "Candidate ids with a raw rank (higher is better). `topic` is a normalized topic or `nil`."
  @callback candidates(scope :: M.scope(), words :: [String.t()], topic :: String.t() | nil, limit :: pos_integer()) ::
              {:ok, [{integer(), number()}]} | {:error, term()}

  @doc "Backend name for `details`."
  @callback name() :: String.t()

  @max_words 12
  @superseded_penalty 10.0

  @doc "Words of a text: lowercase letters and digits, no duplicates, in order."
  @spec words(String.t()) :: [String.t()]
  def words(text) when is_binary(text) do
    ~r/[\p{L}\p{N}]+/u |> Regex.scan(String.downcase(text)) |> List.flatten() |> Enum.uniq()
  end

  @doc "The query words that reach a backend: at most #{@max_words}."
  def query_words(query), do: query |> words() |> Enum.take(@max_words)

  @doc "The backend module for the configured storage."
  @spec backend() :: module()
  def backend do
    case M.config(:search) do
      mod when is_atom(mod) and not is_nil(mod) ->
        mod

      _ ->
        case Application.get_env(:super_pi, :storage_backend, :sqlite) do
          :sqlite -> FTS5
          :postgres -> Tsvector
          _ -> Like
        end
    end
  end

  @doc """
  Searches a scope. Options: `:limit` (default 8, at most 25) and `:topic`.

  Returns `{:ok, %{backend: name, degraded: boolean, words: [..], results: [%{memory, text, recency, score}]}}`
  (best first) or `{:error, :empty_query}`.
  """
  @spec run(M.scope(), String.t(), keyword()) :: {:ok, map()} | {:error, :empty_query}
  def run(scope, query, opts \\ []) do
    words = if is_binary(query), do: query_words(query), else: []
    topic = opts |> Keyword.get(:topic) |> topic_word()
    limit = opts |> Keyword.get(:limit, 8) |> max(1) |> min(25)

    if words == [] and is_nil(topic) do
      {:error, :empty_query}
    else
      {backend, degraded, raw} = candidates(scope, words, topic, max(limit * 4, 20))
      ids = Enum.map(raw, &elem(&1, 0))
      notes = Map.new(Repo.all(from m in Memory, where: m.id in ^ids), &{&1.id, &1})
      max_raw = raw |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> 0 end)

      entries =
        for {id, rank} <- raw, note = notes[id] do
          %{memory: note, text: if(max_raw > 0, do: rank / max_raw, else: 1.0)}
        end

      results = entries |> rank(DateTime.utc_now()) |> Enum.take(limit)
      {:ok, %{backend: backend.name(), degraded: degraded, words: words, results: results}}
    end
  end

  defp topic_word(topic) when is_binary(topic) do
    case M.normalize_topics([topic]) do
      "" -> nil
      t -> t |> String.split(" ") |> hd()
    end
  end

  defp topic_word(_), do: nil

  defp candidates(scope, words, topic, limit) do
    backend = if words == [], do: Like, else: backend()

    case safe_candidates(backend, scope, words, topic, limit) do
      {:ok, raw} ->
        {backend, false, raw}

      {:error, _} when backend == Like ->
        {Like, false, []}

      {:error, _} ->
        raw =
          case safe_candidates(Like, scope, words, topic, limit) do
            {:ok, raw} -> raw
            {:error, _} -> []
          end

        {Like, true, raw}
    end
  end

  defp safe_candidates(backend, scope, words, topic, limit) do
    backend.candidates(scope, words, topic, limit)
  rescue
    e -> {:error, e}
  end

  @doc """
  Scores and orders entries `%{memory, text}` at time `now`. Pure: it reads only its arguments and
  the `:memory` configuration. Each result gains `:recency` and `:score`.
  """
  @spec rank([map()], DateTime.t()) :: [map()]
  def rank(entries, now) do
    half_life = M.config(:half_life_days)
    recency_weight = M.config(:recency_weight)
    bonus = M.config(:pinned_bonus)

    entries
    |> Enum.map(fn %{memory: m, text: text} = e ->
      recency = recency(m.updated_at, now, half_life)

      score =
        text + recency_weight * recency + if(m.pinned, do: bonus, else: 0.0) -
          if(m.superseded_by_id, do: @superseded_penalty, else: 0.0)

      e |> Map.put(:recency, recency) |> Map.put(:score, score)
    end)
    |> apply_supersession()
    |> Enum.sort_by(&{-&1.score, &1.memory.id})
  end

  @doc """
  Clamps every superseded entry below its superseder when both are present. Repeats until stable,
  so a chain A < B < C ends ordered C, B, A. The number of passes is bounded by the number of
  entries, which also stops a corrupt cycle.
  """
  @spec apply_supersession([map()]) :: [map()]
  def apply_supersession(entries), do: clamp(entries, length(entries))

  defp clamp(entries, 0), do: entries

  defp clamp(entries, passes) do
    scores = Map.new(entries, &{&1.memory.id, &1.score})

    {next, changed?} =
      Enum.map_reduce(entries, false, fn e, changed? ->
        case e.memory.superseded_by_id && Map.fetch(scores, e.memory.superseded_by_id) do
          {:ok, superseder} when e.score >= superseder -> {%{e | score: superseder - 1.0e-9}, true}
          _ -> {e, changed?}
        end
      end)

    if changed?, do: clamp(next, passes - 1), else: next
  end

  defp recency(nil, _now, _half_life), do: 0.0

  defp recency(updated_at, now, half_life) do
    age_days = max(DateTime.diff(now, updated_at, :second), 0) / 86_400
    :math.pow(0.5, age_days / half_life)
  end

  @doc "A LIKE pattern for a topic: matches the topic as a whole word of the padded topics column."
  def topic_pattern(nil), do: "%"
  def topic_pattern(topic), do: "% " <> escape_like(topic) <> " %"

  @doc "Escapes `%`, `_` and the escape character `\\` for a LIKE with `ESCAPE '\\'`."
  def escape_like(text), do: String.replace(text, ["\\", "%", "_"], &("\\" <> &1))
end
