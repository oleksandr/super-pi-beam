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
    opts =
      case Application.get_env(:super_pi, :storage_backend, :sqlite) do
        :sqlite -> [mode: :immediate]
        _ -> []
      end

    {:ok, result} =
      Repo.transaction(
        fn ->
          seq = next_seq!()
          drain_pending_deferred_in_tx(seq)
          fun.(seq)
        end,
        opts
      )

    result
  end

  @doc """
  Allocates and returns the next monotonic sequence number (`Seq`).
  """
  def next_seq! do
    case Repo.query!("UPDATE record_ids SET seq = seq + 1 WHERE name = 'global_seq' RETURNING seq").rows do
      [[next]] ->
        next

      [] ->
        Repo.query!("INSERT INTO record_ids (name, seq) VALUES ('global_seq', 1)")
        1
    end
  rescue
    _ ->
      case Repo.query!("SELECT seq FROM record_ids WHERE name = 'global_seq'").rows do
        [[current]] ->
          next = current + 1
          Repo.query!("UPDATE record_ids SET seq = ? WHERE name = 'global_seq'", [next])
          next

        [] ->
          Repo.query!("INSERT INTO record_ids (name, seq) VALUES ('global_seq', 1)")
          1
      end
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
      conv
    end)
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
      current = Doc.snapshot("conversation", conversation_id, "pi.agent") || %{}

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

  defp drain_pending_deferred_in_tx(seq) do
    DeferredFlusher.ensure_pending_ets!()

    case :ets.tab2list(:super_pi_deferred_pending) do
      [] ->
        :ok

      items ->
        :ets.delete_all_objects(:super_pi_deferred_pending)

        Enum.each(items, fn {{scope_kind, scope_id, kind, key}, value} ->
          Doc.put_doc(scope_kind, scope_id, kind, value, seq, key: key)
        end)
    end
  end
end
