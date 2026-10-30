defmodule SuperPi.Memory.Search.Like do
  @moduledoc """
  Naive backend for tests, for a topic-only listing and for any storage without a native index.

  It matches a note when any word is a substring of its title, topics or body, and ranks by word
  hits weighted title 3, topics 2, body 1. It scans the scope, bounded to the 500 most recently
  updated notes, so it is a fallback and not a way to run a large store. It matches substrings
  (`log` matches `catalog`), where the other backends match whole words.
  """

  @behaviour SuperPi.Memory.Search

  import Ecto.Query

  alias SuperPi.Durable.Schemas.Memory
  alias SuperPi.Memory, as: M
  alias SuperPi.Memory.Search

  @scan_limit 500

  @impl true
  def name, do: "like"

  @impl true
  def candidates(scope, words, topic, limit) do
    topic_pat = Search.topic_pattern(topic)

    base =
      from m in M.scoped(scope),
        where: fragment("(' ' || ? || ' ') LIKE ? ESCAPE '\\'", m.topics, ^topic_pat),
        order_by: [desc: m.updated_seq],
        limit: ^@scan_limit

    query =
      case words do
        [] ->
          base

        _ ->
          hit =
            Enum.reduce(words, dynamic(false), fn w, acc ->
              pat = "%" <> Search.escape_like(w) <> "%"

              dynamic(
                [m],
                ^acc or fragment("lower(?) LIKE ? ESCAPE '\\'", m.title, ^pat) or
                  fragment("lower(?) LIKE ? ESCAPE '\\'", m.topics, ^pat) or
                  fragment("lower(?) LIKE ? ESCAPE '\\'", m.body, ^pat)
              )
            end)

          from m in base, where: ^hit
      end

    rows =
      for %Memory{} = m <- SuperPi.Repo.all(query), rank = rank(m, words), rank > 0 do
        {m.id, rank}
      end

    {:ok, rows |> Enum.sort_by(&{-elem(&1, 1), elem(&1, 0)}) |> Enum.take(limit)}
  end

  defp rank(_m, []), do: 1.0

  defp rank(m, words) do
    title = String.downcase(m.title)
    topics = String.downcase(m.topics)
    body = String.downcase(m.body)

    Enum.reduce(words, 0.0, fn w, acc ->
      acc + hit(title, w, 3.0) + hit(topics, w, 2.0) + hit(body, w, 1.0)
    end)
  end

  defp hit(text, word, weight), do: if(String.contains?(text, word), do: weight, else: 0.0)
end
