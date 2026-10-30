defmodule SuperPi.Durable.Storage do
  @moduledoc """
  Transactional durable storage engine (`SuperPi.Durable.Storage`) implementing:
  - Monotonic sequence numbers (`Seq`)
  - Conversation creation (with reserved `ROOT_CONVERSATION_ID = 1`) and atomic built-in documents
  - Conversation forking at any visible entry with `asOf` rewind of `pi.agent` and fresh `pi.provider` UUIDv7
  - Entry appending with `head` markers and `ContextEdit` operations
  """

  alias SuperPi.Repo
  alias SuperPi.Durable.{DeferredFlusher, Doc}
  alias SuperPi.Durable.Schemas.{Conversation, Entry}

  @root_conversation_id 1

  def root_conversation_id, do: @root_conversation_id

  @doc """
  Executes a durable commit, first draining any pending deferred updates (`REQ-DUR-05`)
  and allocating a monotonic `seq` number.
  """
  def commit(fun) when is_function(fun, 1) do
    opts = tx_opts()

    DeferredFlusher.ensure_pending_ets!()
    items_to_drain = :ets.tab2list(:super_pi_deferred_pending)

    Process.put(:super_pi_tx_doc_keys, [])

    result =
      try do
        Repo.transaction(
          fn ->
            # Drained documents get their own seq: `fun` may write the same
            # document, and (document_id, seq) is unique.
            drain_seq = if items_to_drain == [], do: nil, else: next_seq!()
            seq = next_seq!()

            Enum.each(items_to_drain, fn {{scope_kind, scope_id, kind, key}, value} ->
              Doc.put_doc(scope_kind, scope_id, kind, value, drain_seq, key: key)
            end)

            fun.(seq)
          end,
          opts
        )
      rescue
        e ->
          Enum.each(Process.get(:super_pi_tx_doc_keys, []), fn cache_key ->
            :ets.delete(:super_pi_doc_cache, cache_key)
          end)
          Process.delete(:super_pi_tx_doc_keys)
          reraise e, __STACKTRACE__
      catch
        kind, reason ->
          Enum.each(Process.get(:super_pi_tx_doc_keys, []), fn cache_key ->
            :ets.delete(:super_pi_doc_cache, cache_key)
          end)
          Process.delete(:super_pi_tx_doc_keys)
          :erlang.raise(kind, reason, __STACKTRACE__)
      else
        {:ok, res} ->
          Enum.each(items_to_drain, fn {key, val} ->
            case :ets.lookup(:super_pi_deferred_pending, key) do
              [{^key, ^val}] -> :ets.delete(:super_pi_deferred_pending, key)
              _ -> :ok
            end
          end)

          # The commit is done, so other nodes may now drop their cached copies.
          SuperPi.Durable.DocCache.broadcast(Process.get(:super_pi_tx_doc_keys, []))
          Process.delete(:super_pi_tx_doc_keys)
          res

        {:error, reason} ->
          Enum.each(Process.get(:super_pi_tx_doc_keys, []), fn cache_key ->
            :ets.delete(:super_pi_doc_cache, cache_key)
          end)
          Process.delete(:super_pi_tx_doc_keys)
          {:error, reason}
      end

    result
  end

  @doc """
  Options for `Repo.transaction/2`. SQLite takes the write lock up front
  (`BEGIN IMMEDIATE`) so a read-then-write transaction cannot lose a race.
  """
  def tx_opts do
    case Application.get_env(:super_pi, :storage_backend, :sqlite) do
      :sqlite -> [mode: :immediate]
      _ -> []
    end
  end

  @doc "True when the backend supports `SELECT ... FOR UPDATE`."
  def row_locks?, do: Application.get_env(:super_pi, :storage_backend, :sqlite) != :sqlite

  @doc """
  Allocates and returns the next monotonic sequence number (`Seq`).

  One atomic upsert, valid on SQLite and PostgreSQL. The row lock held until
  commit serializes concurrent allocators.
  """
  def next_seq! do
    %{rows: [[next]]} =
      Repo.query!("""
      INSERT INTO record_ids (name, seq) VALUES ('global_seq', 1)
      ON CONFLICT (name) DO UPDATE SET seq = record_ids.seq + 1
      RETURNING seq
      """)

    next
  end

  def current_seq do
    case Repo.query!("SELECT seq FROM record_ids WHERE name = 'global_seq'").rows do
      [[current]] -> current
      _ -> 0
    end
  rescue
    _ -> 0
  end

  @doc """
  The most recently created top-level conversation (no owning task), or `nil`.
  Used by `--continue`.
  """
  def latest_conversation do
    import Ecto.Query

    Repo.one(
      from c in Conversation,
        where: is_nil(c.owner_task_id) and is_nil(c.parent_conversation_id),
        order_by: [desc: c.id],
        limit: 1
    )
  end

  @doc """
  Opens or lazily creates the root conversation (`id = 1`) with its 5 built-in documents (`spec.md` §2.5).
  """
  def ensure_root_conversation!(agent_config \\ %{}) do
    case Repo.get(Conversation, @root_conversation_id) do
      %Conversation{} = existing ->
        existing

      nil ->
        create_conversation!(owner_kind: "ownerless", agent: agent_config, id: @root_conversation_id)
    end
  end

  @doc """
  Atomically creates a conversation and initializes its 5 built-in documents:
  `pi.agent`, `pi.provider` (UUIDv7), `pi.live`, `pi.inbox`, and `pi.usage`.
  """
  def create_conversation!(opts \\ []) do
    owner_kind = Keyword.get(opts, :owner_kind, "ownerless")
    owner_task_id = Keyword.get(opts, :owner_task_id)
    parent_conversation_id = Keyword.get(opts, :parent_conversation_id)
    parent_entry_id = Keyword.get(opts, :parent_entry_id)
    agent_override = Keyword.get(opts, :agent, %{})
    explicit_id = Keyword.get(opts, :id)

    commit(fn seq ->
      attrs = %{
        owner_kind: owner_kind,
        owner_task_id: owner_task_id,
        parent_conversation_id: parent_conversation_id,
        parent_entry_id: parent_entry_id,
        created_seq: seq
      }

      attrs = if explicit_id, do: Map.put(attrs, :id, explicit_id), else: attrs

      conv =
        %Conversation{}
        |> Conversation.changeset(attrs)
        |> Repo.insert!()

      init_builtin_docs!(conv.id, agent_override, seq)
      put_owner(conv.id, Keyword.get(opts, :owner), seq)
      conv
    end)
  end

  # `pi.owner` is written in the commit that creates the conversation, so a crash cannot leave an
  # unowned conversation that `"anonymous"` could claim.
  defp put_owner(_conv_id, nil, _seq), do: :ok

  defp put_owner(conv_id, owner, seq) when is_binary(owner) do
    Doc.put_doc("conversation", conv_id, "pi.owner", %{"principal" => owner}, seq)
    :ok
  end

  @doc """
  Atomically forks `parent_conversation_id` at `at_entry_id` (`spec.md` §2.5, §3.7):
  - Copies `pi.agent` `asOf` the target entry's commit `seq`
  - Mints a fresh `pi.provider` UUIDv7 (forks never copy parent's provider UUID)
  - Initializes fresh `pi.live`, `pi.inbox`, and `pi.usage` documents
  """
  def fork_conversation!(parent_conversation_id, at_entry_id, opts \\ []) do
    owner_kind = Keyword.get(opts, :owner_kind, "ownerless")
    owner_task_id = Keyword.get(opts, :owner_task_id)
    agent_override = Keyword.get(opts, :agent, %{})

    commit(fn seq ->
      target_entry = Repo.get!(Entry, at_entry_id)

      if target_entry.conversation_id != parent_conversation_id do
        Repo.active_repo().rollback(:foreign_entry)
      end

      as_of_agent =
        Doc.snapshot_as_of(parent_conversation_id, "pi.agent", target_entry.seq) || %{}

      merged_agent = Map.merge(as_of_agent, agent_override)

      conv =
        %Conversation{}
        |> Conversation.changeset(%{
          parent_conversation_id: parent_conversation_id,
          parent_entry_id: at_entry_id,
          owner_kind: owner_kind,
          owner_task_id: owner_task_id,
          created_seq: seq
        })
        |> Repo.insert!()

      init_builtin_docs!(conv.id, merged_agent, seq)
      put_owner(conv.id, Keyword.get(opts, :owner), seq)
      conv
    end)
  end

  @doc """
  Appends an immutable entry to `conversation_id`.
  Supports `head_entry_id: :self` (used by `pi.reset`) or an explicit integer `EntryId` (used by `pi.compaction`).
  """
  def append_entry!(conversation_id, kind, data, opts \\ []) when is_map(data) do
    head_opt = Keyword.get(opts, :head_entry_id)
    edits = Keyword.get(opts, :edits, [])

    commit(fn seq ->
      entry =
        %Entry{}
        |> Entry.changeset(%{
          conversation_id: conversation_id,
          seq: seq,
          kind: kind,
          head_entry_id: if(is_integer(head_opt), do: head_opt, else: nil),
          edits: %{"items" => edits},
          data: data
        })
        |> Repo.insert!()

      if head_opt == :self do
        entry
        |> Entry.changeset(%{head_entry_id: entry.id})
        |> Repo.update!()
      else
        entry
      end
    end)
  end

  @doc """
  Updates the conversation's `pi.agent` rewindable document (`Conversation.configure()`).
  """
  def configure_agent!(conversation_id, changes) when is_map(changes) do
    commit(fn seq ->
      # Read the database, not the cache: another node may have written the document.
      current = Doc.snapshot_for_update("conversation", conversation_id, "pi.agent") || %{}

      updated =
        Enum.reduce(changes, current, fn
          {k, nil}, acc -> Map.delete(acc, to_string(k))
          {k, v}, acc -> Map.put(acc, to_string(k), v)
        end)

      {:ok, val} = Doc.put_doc("conversation", conversation_id, "pi.agent", updated, seq)
      val
    end)
  end

  defp init_builtin_docs!(conv_id, initial_agent, seq) do
    Doc.put_doc("conversation", conv_id, "pi.agent", initial_agent, seq)
    Doc.put_doc("conversation", conv_id, "pi.provider", %{"sessionId" => Uniq.UUID.uuid7()}, seq)
    Doc.put_doc("conversation", conv_id, "pi.live", %{"status" => "idle"}, seq)
    Doc.put_doc("conversation", conv_id, "pi.inbox", %{"queued" => []}, seq)
    Doc.put_doc("conversation", conv_id, "pi.usage", %{"inputTokens" => 0, "outputTokens" => 0, "costUsd" => 0.0}, seq)
  end

end
