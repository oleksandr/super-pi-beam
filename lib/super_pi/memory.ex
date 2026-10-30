defmodule SuperPi.Memory do
  @moduledoc """
  Durable notes that outlive a conversation: the store behind `SuperPi.Plugins.Memory`.

  Notes live in the `memories` table, not in a durable document and not in artifacts. A document
  rewrites the whole corpus as one base row at every checkpoint and pins it in ETS, and artifacts
  have no search and die with their conversation. A note belongs to a scope `{scope_kind, scope_id}`:
  `{"owner", principal}` by default or `{"global", ""}`. It is not forked and not rewound, so a note
  that a branch writes is visible to its parent. Read-only subagents cannot write one, because
  `memory_write` carries the `state_write` effect and plan mode blocks it.

  ## Writing

  `write/3` validates, then inserts or updates in one `Storage.commit/1` (the index triggers run in
  the same transaction). Limits and rules:

  - Title and body are stored byte for byte. They must be valid UTF-8 without NUL (PostgreSQL
    cannot store NUL) and the body is capped at `:max_body_bytes` (32 000 by default).
  - An explicit `slug` upserts. A slug derived from the title never overwrites: a taken one gets `-2`, `-3`.
  - `pinned` is refused for compaction provenance and for a note with `source.url`, unless the
    caller passes `allow_pin_untrusted: true`. A pinned body goes into the system prompt, so
    anything from the open internet needs an explicit opt-in. An update takes `pinned` from the call
    (default `false`), so rewriting a pinned note unpins it.
  - Provenance is not model-settable: `web` when `source.url` is set, else `agent`. Code passes
    `:provenance` (`user`, `compaction`, `import`).
  - The result lists similar live notes with a score, which keeps the store from becoming a junk
    drawer. The score is the Jaccard similarity of title and topic words, which does not depend on
    the search backend.

  ## Reading and linking

  `search/3` is lexical (`SuperPi.Memory.Search`). `read/2` returns a note with its links.
  `link/5` adds a `related`, `derived_from` or `supersedes` edge. `supersedes` marks the older note
  superseded, refuses a cycle and refuses a note that already has a superseder.

  Configuration (`config :super_pi, :memory, [...]`): `:max_body_bytes`, `:index_token_budget`,
  `:pinned_body_bytes`, `:half_life_days`, `:recency_weight`, `:pinned_bonus`, `:duplicate_threshold`,
  `:search` (backend module), `:harvest_model`, `:harvest_max_facts`, `:harvest_llm`.
  """

  import Ecto.Query

  alias SuperPi.Durable.Schemas.{Entry, Memory, MemoryLink}
  alias SuperPi.Durable.Storage
  alias SuperPi.Memory.Search
  alias SuperPi.Repo

  @type scope :: {String.t(), String.t()}

  @defaults [
    max_body_bytes: 32_000,
    index_token_budget: 2_000,
    pinned_body_bytes: 1_500,
    half_life_days: 30.0,
    recency_weight: 0.25,
    pinned_bonus: 0.2,
    duplicate_threshold: 0.5,
    search: nil,
    harvest_model: "gemini-3-flash-preview",
    harvest_max_facts: 8,
    harvest_llm: nil
  ]

  @provenances ~w(agent user web compaction import)
  @rels ~w(related derived_from supersedes)
  @source_keys ~w(url artifact note conversation_id head_entry_id)
  @slug_re ~r/\A[a-z0-9][a-z0-9._-]{0,63}\z/

  @doc "A configuration value, with the module default."
  @spec config(atom()) :: term()
  def config(key) do
    :super_pi |> Application.get_env(:memory, []) |> Keyword.get_lazy(key, fn -> Keyword.fetch!(@defaults, key) end)
  end

  def provenances, do: @provenances
  def rels, do: @rels

  @doc "The scope of a conversation: its owner's notes by default, or the shared `global` scope."
  @spec scope(integer() | nil, keyword()) :: scope()
  def scope(conversation_id, opts \\ []) do
    case Keyword.get(opts, :scope, :owner) do
      :global -> {"global", ""}
      _ -> {"owner", if(is_integer(conversation_id), do: SuperPi.Auth.owner(conversation_id), else: SuperPi.Auth.anonymous())}
    end
  end

  @doc "The query of every note in a scope."
  def scoped({kind, id}), do: from(m in Memory, where: m.scope_kind == ^kind and m.scope_id == ^id)

  # --- Writing ---

  @doc """
  Writes a note. `attrs` has string keys: `"title"`, `"body"`, and optionally `"slug"`, `"topics"`
  (list of strings), `"pinned"`, `"confidence"` (0..1) and `"source"` (map with `url`, `artifact`, `note`).

  Options: `:conversation_id` (origin), `:provenance`, `:allow_pin_untrusted`.

  Returns `{:ok, %{memory: note, created: boolean, similar: [%{slug, title, score}]}}` or `{:error, reason}`
  (see `format_error/1`).
  """
  @spec write(scope(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def write(scope, attrs, opts \\ []) when is_map(attrs) do
    with {:ok, n} <- normalize(attrs, opts) do
      origin = Keyword.get(opts, :conversation_id)

      result =
        Storage.commit(fn seq ->
          case persist(scope, n, seq, origin) do
            {:ok, memory, created} -> {:ok, memory, created}
            {:error, reason} -> Repo.active_repo().rollback(reason)
          end
        end)

      case result do
        {:ok, memory, created} ->
          {:ok, %{memory: memory, created: created, similar: similar(scope, memory)}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp normalize(attrs, opts) do
    title = attrs["title"]
    body = attrs["body"]

    with :ok <- check_text(:title, title, 400),
         :ok <- check_text(:body, body, config(:max_body_bytes)),
         {:ok, slug} <- check_slug(attrs["slug"]),
         {:ok, source} <- normalize_source(attrs["source"]),
         {:ok, provenance} <- provenance(opts, source),
         pinned = attrs["pinned"] == true,
         :ok <- check_pin(pinned, provenance, source, opts) do
      {:ok,
       %{
         title: title,
         body: body,
         slug: slug,
         topics: normalize_topics(attrs["topics"]),
         pinned: pinned,
         confidence: confidence(attrs["confidence"], provenance),
         source: source,
         provenance: provenance
       }}
    end
  end

  defp check_text(field, text, max_bytes) do
    cond do
      not is_binary(text) -> {:error, {:invalid, field, "is required and must be a string"}}
      not String.valid?(text) -> {:error, {:invalid, field, "is not valid UTF-8"}}
      String.contains?(text, <<0>>) -> {:error, {:invalid, field, "contains a NUL byte"}}
      String.trim(text) == "" -> {:error, {:invalid, field, "is empty"}}
      byte_size(text) > max_bytes -> {:error, {:invalid, field, "is over #{max_bytes} bytes"}}
      true -> :ok
    end
  end

  defp check_slug(nil), do: {:ok, nil}

  defp check_slug(slug) when is_binary(slug) do
    if Regex.match?(@slug_re, slug),
      do: {:ok, slug},
      else: {:error, {:invalid, :slug, "must match [a-z0-9][a-z0-9._-]{0,63}"}}
  end

  defp check_slug(_), do: {:error, {:invalid, :slug, "must be a string"}}

  defp normalize_source(nil), do: {:ok, %{}}

  defp normalize_source(%{} = source) do
    source = for {k, v} <- source, to_string(k) in @source_keys, valid_source_value?(v), into: %{}, do: {to_string(k), v}

    case source do
      %{"url" => url} ->
        if match?(%URI{scheme: s, host: h} when s in ["http", "https"] and is_binary(h), URI.parse(url)) and byte_size(url) <= 2048,
          do: {:ok, source},
          else: {:error, {:invalid, :source, "url must be an http(s) URL of at most 2048 bytes"}}

      _ ->
        {:ok, source}
    end
  end

  defp normalize_source(_), do: {:error, {:invalid, :source, "must be an object"}}

  defp valid_source_value?(v) when is_binary(v), do: String.valid?(v) and byte_size(v) <= 2048 and not String.contains?(v, <<0>>)
  defp valid_source_value?(v), do: is_integer(v)

  defp provenance(opts, source) do
    case Keyword.get(opts, :provenance) do
      nil -> {:ok, if(Map.has_key?(source, "url"), do: "web", else: "agent")}
      p when p in @provenances -> {:ok, p}
      other -> {:error, {:invalid, :provenance, "unknown #{inspect(other)}"}}
    end
  end

  defp check_pin(false, _provenance, _source, _opts), do: :ok

  defp check_pin(true, provenance, source, opts) do
    if (provenance == "compaction" or Map.has_key?(source, "url")) and not Keyword.get(opts, :allow_pin_untrusted, false),
      do: {:error, :pin_refused},
      else: :ok
  end

  @default_confidence %{"user" => 0.9, "agent" => 0.7, "import" => 0.6, "web" => 0.5, "compaction" => 0.3}

  defp confidence(c, _provenance) when is_number(c), do: c |> max(0.0) |> min(1.0) |> Kernel.*(1.0)
  defp confidence(_, provenance), do: Map.fetch!(@default_confidence, provenance)

  @doc """
  Normalizes topics to a space-separated string of lowercase words. Anything outside letters,
  digits, `.`, `_` and `-` becomes `-`. At most 8 topics of 40 characters.
  """
  @spec normalize_topics(term()) :: String.t()
  def normalize_topics(list) when is_list(list) do
    list
    |> Enum.filter(&(is_binary(&1) and String.valid?(&1)))
    |> Enum.map(fn t ->
      t |> String.downcase() |> String.trim() |> String.replace(~r/[^\p{L}\p{N}._-]+/u, "-") |> String.trim("-") |> String.slice(0, 40)
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.take(8)
    |> Enum.join(" ")
  end

  def normalize_topics(_), do: ""

  @doc "The topics of a note as a list."
  def topic_list(%Memory{topics: t}), do: String.split(t, " ", trim: true)

  defp persist(scope, n, seq, origin) do
    {kind, id} = scope

    existing = if n.slug, do: Repo.get_by(Memory, scope_kind: kind, scope_id: id, slug: n.slug)
    slug = n.slug || free_slug(scope, n.title)

    fields = %{
      title: n.title,
      body: n.body,
      topics: n.topics,
      provenance: n.provenance,
      confidence: n.confidence,
      source: n.source,
      pinned: n.pinned,
      updated_seq: seq
    }

    case existing do
      nil ->
        attrs =
          Map.merge(fields, %{
            scope_kind: kind,
            scope_id: id,
            slug: slug,
            created_seq: seq,
            origin_conversation_id: origin,
            origin_entry_seq: origin_entry_seq(origin)
          })

        case %Memory{} |> Memory.changeset(attrs) |> Repo.insert() do
          {:ok, m} -> {:ok, m, true}
          {:error, cs} -> {:error, {:db, cs}}
        end

      %Memory{} = m ->
        case m |> Memory.changeset(fields) |> Repo.update() do
          {:ok, m} -> {:ok, m, false}
          {:error, cs} -> {:error, {:db, cs}}
        end
    end
  end

  defp origin_entry_seq(conversation_id) when is_integer(conversation_id),
    do: Repo.one(from e in Entry, where: e.conversation_id == ^conversation_id, select: max(e.seq))

  defp origin_entry_seq(_), do: nil

  @doc "Derives a slug from a title: ASCII words joined by `-`, or a short hash when no ASCII word is left."
  @spec slugify(String.t()) :: String.t()
  def slugify(title) do
    base =
      title
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 56)
      |> String.trim("-")

    if base == "", do: "note-" <> (:crypto.hash(:sha256, title) |> Base.encode16(case: :lower) |> binary_part(0, 10)), else: base
  end

  defp free_slug(scope, title) do
    base = slugify(title)

    Enum.find_value(1..1000, fn i ->
      candidate = if i == 1, do: base, else: String.slice(base, 0, 60) <> "-#{i}"
      if get(scope, candidate), do: nil, else: candidate
    end) || raise "no free slug for #{inspect(title)}"
  end

  # --- Duplicates ---

  defp similar(scope, %Memory{} = memory) do
    words = word_set(memory.title <> " " <> memory.topics)
    threshold = config(:duplicate_threshold)

    case Search.run(scope, Enum.join(words, " "), limit: 10) do
      {:ok, %{results: results}} ->
        for %{memory: m} <- results,
            m.slug != memory.slug,
            is_nil(m.superseded_by_id),
            score = jaccard(words, word_set(m.title <> " " <> m.topics)),
            score >= threshold do
          %{slug: m.slug, title: m.title, score: Float.round(score, 2)}
        end
        |> Enum.sort_by(&(-&1.score))
        |> Enum.take(3)

      _ ->
        []
    end
  end

  defp word_set(text), do: text |> Search.words() |> MapSet.new()

  defp jaccard(a, b) do
    union = MapSet.union(a, b) |> MapSet.size()
    if union == 0, do: 0.0, else: MapSet.intersection(a, b) |> MapSet.size() |> Kernel./(union)
  end

  # --- Reading ---

  @doc "The note with `slug` in the scope, or `nil`."
  @spec get(scope(), String.t()) :: Memory.t() | nil
  def get({kind, id}, slug) when is_binary(slug), do: Repo.get_by(Memory, scope_kind: kind, scope_id: id, slug: slug)
  def get(_scope, _slug), do: nil

  @doc """
  Reads a note with its outgoing links, its backlinks and the slug of its superseder.
  Returns `{:ok, %{memory, links: [{rel, note}], backlinks: [{rel, note}], superseded_by: slug | nil}}`
  or `{:error, :not_found}`.
  """
  def read(scope, slug) do
    case get(scope, slug) do
      nil ->
        {:error, :not_found}

      %Memory{id: id} = m ->
        out = Repo.all(from l in MemoryLink, join: t in Memory, on: t.id == l.to_id, where: l.from_id == ^id, order_by: [l.id], select: {l.rel, t})
        back = Repo.all(from l in MemoryLink, join: f in Memory, on: f.id == l.from_id, where: l.to_id == ^id, order_by: [l.id], select: {l.rel, f})
        superseder = m.superseded_by_id && Repo.one(from s in Memory, where: s.id == ^m.superseded_by_id, select: s.slug)
        {:ok, %{memory: m, links: out, backlinks: back, superseded_by: superseder}}
    end
  end

  @doc "Searches the scope. See `SuperPi.Memory.Search.run/3`."
  defdelegate search(scope, query, opts \\ []), to: Search, as: :run

  @doc """
  A short window of `body` around the first query word, or the start of the body. Whitespace is collapsed.
  """
  @spec snippet(String.t(), [String.t()], pos_integer()) :: String.t()
  def snippet(body, tokens, width \\ 160) do
    flat = body |> String.replace(~r/\s+/u, " ") |> String.trim()
    down = String.downcase(flat)

    start =
      Enum.find_value(tokens, 0, fn t ->
        case String.split(down, t, parts: 2) do
          [before, _] -> max(String.length(before) - div(width, 4), 0)
          _ -> nil
        end
      end)

    piece = flat |> String.slice(start, width) |> String.trim()
    (if start > 0, do: "..." <> piece, else: piece) <> if(String.length(flat) > start + width, do: "...", else: "")
  end

  # --- Linking ---

  @doc """
  Adds a `rel` edge from the note `from_slug` to `to_slug`. `supersedes` marks `to` as replaced by
  `from`. Idempotent for an existing edge.
  """
  @spec link(scope(), String.t(), String.t(), String.t(), keyword()) :: {:ok, %{from: Memory.t(), to: Memory.t(), rel: String.t()}} | {:error, term()}
  def link(scope, from_slug, to_slug, rel, _opts \\ []) do
    cond do
      rel not in @rels -> {:error, {:invalid, :rel, "must be one of #{Enum.join(@rels, ", ")}"}}
      from_slug == to_slug -> {:error, {:invalid, :to, "a note cannot link to itself"}}
      true -> do_link(scope, from_slug, to_slug, rel)
    end
  end

  defp do_link(scope, from_slug, to_slug, rel) do
    Storage.commit(fn seq ->
      with {:ok, from} <- fetch(scope, from_slug),
           {:ok, to} <- fetch(scope, to_slug),
           :ok <- check_supersede(rel, from, to),
           {:ok, _} <-
             Repo.insert(MemoryLink.changeset(%MemoryLink{}, %{from_id: from.id, to_id: to.id, rel: rel, created_seq: seq}),
               on_conflict: :nothing,
               conflict_target: [:from_id, :to_id, :rel]
             ) do
        to = if rel == "supersedes", do: mark_superseded!(to, from, seq), else: to
        {:ok, %{from: from, to: to, rel: rel}}
      else
        {:error, reason} -> Repo.active_repo().rollback(reason)
      end
    end)
  end

  defp fetch(scope, slug), do: if(m = get(scope, slug), do: {:ok, m}, else: {:error, {:not_found, slug}})

  defp check_supersede("supersedes", from, to) do
    cond do
      to.superseded_by_id == from.id -> :ok
      to.superseded_by_id -> {:error, {:already_superseded, Repo.get!(Memory, to.superseded_by_id).slug}}
      superseded_chain_reaches?(from, to.id, MapSet.new()) -> {:error, :cycle}
      true -> :ok
    end
  end

  defp check_supersede(_rel, _from, _to), do: :ok

  # `from` is already replaced, directly or not, by `target_id`: the edge would close a loop.
  defp superseded_chain_reaches?(%Memory{superseded_by_id: nil}, _target, _seen), do: false
  defp superseded_chain_reaches?(%Memory{superseded_by_id: id}, target, _seen) when id == target, do: true

  defp superseded_chain_reaches?(%Memory{superseded_by_id: id}, target, seen) do
    if MapSet.member?(seen, id), do: true, else: superseded_chain_reaches?(Repo.get!(Memory, id), target, MapSet.put(seen, id))
  end

  defp mark_superseded!(to, from, seq) do
    to |> Memory.changeset(%{superseded_by_id: from.id, updated_seq: seq}) |> Repo.update!()
  end

  @doc "Human-readable message for an error from `write/3` or `link/5`."
  @spec format_error(term()) :: String.t()
  def format_error({:invalid, field, why}), do: "#{field} #{why}."
  def format_error(:pin_refused), do: "pinned is refused: a note from compaction or from a URL is not pinned without an operator opt-in."
  def format_error({:not_found, slug}), do: "No memory with slug `#{slug}`."
  def format_error(:not_found), do: "No such memory."
  def format_error({:already_superseded, slug}), do: "That note is already superseded by `#{slug}`. Supersede the newest note instead."
  def format_error(:cycle), do: "That link would make a supersede cycle."
  def format_error({:db, %Ecto.Changeset{errors: errors}}), do: "Could not store the note: #{inspect(errors)}."
  def format_error(other), do: "Memory error: #{inspect(other)}."

  # --- Index support ---

  @doc "`{count, max updated_seq}` of the scope: cheap proof that the index text is still current."
  @spec fingerprint(scope()) :: String.t()
  def fingerprint(scope) do
    {count, max_seq} = Repo.one(from m in scoped(scope), select: {count(m.id), max(m.updated_seq)})
    "#{count}:#{max_seq || 0}"
  end
end
