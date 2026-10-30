defmodule SuperPi.Durable.Doc do
  @moduledoc """
  Scoped JSON document manager supporting `latest` and `rewindable` (`fork: "as_of"`) policies.

  Rewindable documents store base snapshots and RFC 6902 (`Jsonpatch`) operational deltas
  stamped with the commit `seq`, enabling exact historical reconstruction on conversation fork
  via `snapshot_as_of/3`. Active snapshots are cached in `:ets` (`:super_pi_doc_cache`).
  """

  import Ecto.Query
  alias SuperPi.Repo
  alias SuperPi.Durable.Schemas.{Conversation, Document, DocumentRevision}

  @ets_table :super_pi_doc_cache
  @max_deltas_before_checkpoint 16

  @builtin_specs %{
    "pi.agent" => %{
      scope_kind: "conversation",
      history_policy: "rewindable",
      fork_policy: "as_of",
      checkpoint_every: 4
    },
    "pi.provider" => %{
      scope_kind: "conversation",
      history_policy: "latest",
      fork_policy: "initial",
      checkpoint_every: 1
    },
    "pi.live" => %{
      scope_kind: "conversation",
      history_policy: "latest",
      fork_policy: "initial",
      checkpoint_every: 8
    },
    "pi.inbox" => %{
      scope_kind: "conversation",
      history_policy: "latest",
      fork_policy: "initial",
      checkpoint_every: 4
    },
    "pi.usage" => %{
      scope_kind: "conversation",
      history_policy: "latest",
      fork_policy: "initial",
      checkpoint_every: 8
    },
    # Digest of the Memory plugin's index, one document per memory scope (the `key`). It is not
    # conversation-scoped, so a fork never copies it. Notes live in the `memories` table.
    "pi.memory_index" => %{
      scope_kind: "memory",
      history_policy: "latest",
      fork_policy: "current",
      checkpoint_every: 1
    }
  }

  def ensure_ets! do
    case :ets.whereis(@ets_table) do
      :undefined ->
        :ets.new(@ets_table, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])

      _tid ->
        @ets_table
    end
  end

  def builtin_spec(kind), do: Map.get(@builtin_specs, kind)

  @doc """
  Creates or updates a scoped document at `seq` and caches the new immutable snapshot in ETS.
  """
  def put_doc(scope_kind, scope_id, kind, new_value, seq, opts \\ []) when is_map(new_value) do
    ensure_ets!()
    key = Keyword.get(opts, :key, "")
    spec = Map.get(@builtin_specs, kind, %{})
    history_policy = Keyword.get(opts, :history_policy, Map.get(spec, :history_policy, "latest"))
    fork_policy = Keyword.get(opts, :fork_policy, Map.get(spec, :fork_policy, "current"))
    checkpoint_every = Keyword.get(opts, :checkpoint_every, Map.get(spec, :checkpoint_every, @max_deltas_before_checkpoint))

    doc =
      case find_active_doc(scope_kind, scope_id, kind, key) do
        nil ->
          %Document{}
          |> Document.changeset(%{
            kind: kind,
            key: key,
            scope_kind: scope_kind,
            scope_id: scope_id,
            history_policy: history_policy,
            fork_policy: fork_policy,
            created_seq: seq
          })
          |> Repo.insert!()

        existing ->
          existing
      end

    {prev_value, deltas_since_base} = reconstruct_doc_value(doc.id, nil)
    is_first = prev_value == nil
    is_base = is_first or doc.history_policy == "latest" or deltas_since_base + 1 >= checkpoint_every
    ops = if is_base, do: [], else: compute_ops(prev_value, new_value)

    %DocumentRevision{}
    |> DocumentRevision.changeset(%{
      document_id: doc.id,
      seq: seq,
      version: 1,
      is_checkpoint_base: is_base,
      value: if(is_base, do: new_value, else: nil),
      ops: %{"ops" => ops}
    })
    |> Repo.insert!()

    if doc.history_policy == "latest" do
      rev_ids =
        Repo.all(
          from r in DocumentRevision,
            where: r.document_id == ^doc.id,
            order_by: [desc: r.seq],
            select: r.id
        )

      case Enum.drop(rev_ids, 2) do
        [] ->
          :ok

        old_ids ->
          Repo.delete_all(from r in DocumentRevision, where: r.id in ^old_ids)
      end
    end

    cache_key = {scope_kind, scope_id, kind, key}
    if keys = Process.get(:super_pi_tx_doc_keys) do
      Process.put(:super_pi_tx_doc_keys, [cache_key | keys])
    end

    cache_put(cache_key, new_value, seq)
    {:ok, new_value}
  end

  @doc """
  Writes a fast in-memory ETS overlay for deferred commits (`100ms` streaming updates).
  """
  def put_ets_overlay(scope_kind, scope_id, kind, value, seq, key \\ "") do
    ensure_ets!()
    # Staged value: authoritative on this node until it is flushed, so it never expires.
    cache_put({scope_kind, scope_id, kind, key}, value, seq, :pinned)
    :ok
  end

  # --- Cache ---
  #
  # Entries are `{key, value, seq, cached_at}`. Another node can write a document, so on a
  # cluster the cache is also invalidated by message (`SuperPi.Durable.DocCache`) and an entry
  # expires after `doc_cache_ttl_ms` (default 5 s when nodes are connected, never on one node). The
  # TTL bounds the damage of a read that races an invalidation.

  defp cache_put(key, value, seq, cached_at \\ nil) do
    :ets.insert(@ets_table, {key, value, seq, cached_at || System.monotonic_time(:millisecond)})
  end

  defp cache_get(key) do
    case :ets.lookup(@ets_table, key) do
      [{_, value, _seq, :pinned}] ->
        {:ok, value}

      [{_, value, _seq, cached_at}] ->
        case ttl() do
          :infinity ->
            {:ok, value}

          ttl_ms ->
            if System.monotonic_time(:millisecond) - cached_at < ttl_ms do
              {:ok, value}
            else
              :ets.delete(@ets_table, key)
              :miss
            end
        end

      [] ->
        :miss
    end
  end

  defp ttl do
    case Application.get_env(:super_pi, :doc_cache_ttl_ms, :auto) do
      :auto -> if Node.list() == [], do: :infinity, else: 5_000
      other -> other
    end
  end

  @doc "Removes cache entries (another node wrote these documents)."
  def cache_invalidate(keys) when is_list(keys) do
    ensure_ets!()
    Enum.each(keys, &:ets.delete(@ets_table, &1))
    :ok
  end

  @doc """
  Reads the latest value of a document from the database, never from the cache, and (on
  PostgreSQL) locks its row until the transaction ends. Use it for a read-modify-write inside
  `SuperPi.Durable.Storage.commit/1`: a cached copy may be older than what another node wrote.
  """
  def snapshot_for_update(scope_kind, scope_id, kind, key \\ "") do
    query =
      from d in Document,
        where:
          d.scope_kind == ^scope_kind and d.scope_id == ^scope_id and d.kind == ^kind and d.key == ^key and
            is_nil(d.retired_seq),
        order_by: [desc: d.id],
        limit: 1

    query = if SuperPi.Durable.Storage.row_locks?(), do: lock(query, "FOR UPDATE"), else: query

    case Repo.one(query) do
      nil ->
        nil

      doc ->
        {val, _} = reconstruct_doc_value(doc.id, nil)
        val
    end
  end

  @doc """
  Reads the latest snapshot of a document, checking ETS first before reconstructing from Ecto.
  """
  def snapshot(scope_kind, scope_id, kind, key \\ "") do
    ensure_ets!()

    case cache_get({scope_kind, scope_id, kind, key}) do
      {:ok, value} ->
        value

      :miss ->
        case find_active_doc(scope_kind, scope_id, kind, key) do
          nil ->
            nil

          doc ->
            {val, _count} = reconstruct_doc_value(doc.id, nil)
            if val != nil, do: cache_put({scope_kind, scope_id, kind, key}, val, doc.created_seq)
            val
        end
    end
  end

  @doc """
  Reconstructs a rewindable conversation document (`pi.agent`) as of `at_seq`, walking
  conversation fork ancestry when `at_seq` predates the fork point (`spec.md` §3.3).
  """
  def snapshot_as_of(conversation_id, kind, at_seq, key \\ "") when is_integer(at_seq) do
    {owner_conv_id, effective_seq} = resolve_ancestor_conversation_at_seq(conversation_id, at_seq)

    query =
      from d in Document,
        where:
          d.scope_kind == "conversation" and
            d.scope_id == ^owner_conv_id and
            d.kind == ^kind and
            d.key == ^key and
            d.created_seq <= ^effective_seq and
            (is_nil(d.retired_seq) or d.retired_seq > ^effective_seq),
        order_by: [desc: d.created_seq],
        limit: 1

    case Repo.one(query) do
      nil ->
        nil

      doc ->
        {val, _} = reconstruct_doc_value(doc.id, effective_seq)
        val
    end
  end

  # A fork sees its parent only up to the fork entry. Parent writes after that
  # entry (but before the fork was created) are not part of the fork's history,
  # so the lookup seq is clamped to the fork entry's seq.
  defp resolve_ancestor_conversation_at_seq(conversation_id, at_seq) do
    case Repo.get(Conversation, conversation_id) do
      nil ->
        {conversation_id, at_seq}

      %Conversation{created_seq: created_seq, parent_conversation_id: parent_id} = conv
      when not is_nil(parent_id) and at_seq < created_seq ->
        resolve_ancestor_conversation_at_seq(parent_id, min(at_seq, fork_entry_seq(conv, at_seq)))

      _ ->
        {conversation_id, at_seq}
    end
  end

  defp fork_entry_seq(%Conversation{parent_entry_id: nil}, at_seq), do: at_seq

  defp fork_entry_seq(%Conversation{parent_entry_id: entry_id}, at_seq) do
    case Repo.get(SuperPi.Durable.Schemas.Entry, entry_id) do
      nil -> at_seq
      entry -> entry.seq
    end
  end

  defp find_active_doc(scope_kind, scope_id, kind, key) do
    Repo.one(
      from d in Document,
        where:
          d.scope_kind == ^scope_kind and
            d.scope_id == ^scope_id and
            d.kind == ^kind and
            d.key == ^key and
            is_nil(d.retired_seq),
        order_by: [desc: d.id],
        limit: 1
    )
  end

  defp reconstruct_doc_value(document_id, max_seq) do
    revs_query =
      from r in DocumentRevision,
        where: r.document_id == ^document_id,
        order_by: [asc: r.seq, asc: r.id]

    revs_query =
      if is_integer(max_seq) do
        from r in revs_query, where: r.seq <= ^max_seq
      else
        revs_query
      end

    revs = Repo.all(revs_query)

    case split_from_last_base(revs) do
      {nil, []} ->
        {nil, 0}

      {base_rev, delta_revs} ->
        final_val =
          Enum.reduce(delta_revs, base_rev.value || %{}, fn rev, acc ->
            apply_ops(acc, Map.get(rev.ops, "ops", []))
          end)

        {final_val, length(delta_revs)}
    end
  end

  defp split_from_last_base([]), do: {nil, []}

  defp split_from_last_base(revs) do
    case Enum.split_while(Enum.reverse(revs), fn r -> not r.is_checkpoint_base end) do
      {deltas_rev, [base | _older]} -> {base, Enum.reverse(deltas_rev)}
      {deltas_rev, []} -> {hd(Enum.reverse(deltas_rev)), tl(Enum.reverse(deltas_rev))}
    end
  end

  defp compute_ops(old_map, new_map) do
    old_map
    |> Jsonpatch.diff(new_map)
    |> Enum.map(fn op -> Map.new(op, fn {k, v} -> {to_string(k), v} end) end)
  end

  defp apply_ops(base_map, []), do: base_map

  defp apply_ops(base_map, ops_maps) do
    case Jsonpatch.apply_patch(ops_maps, base_map) do
      {:ok, patched} ->
        patched

      {:error, reason} ->
        raise "Failed to apply JSON patch ops: #{inspect(reason)}"
    end
  end
end
