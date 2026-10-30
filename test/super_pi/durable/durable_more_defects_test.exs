defmodule SuperPi.Durable.DurableMoreDefectsTest do
  @moduledoc """
  Regression tests for further durable-layer defects from the code review. Every
  test is expected to FAIL on the current code and pass once the finding is fixed.

  Run only these:  mix test --only known_bug
  Skip these:      mix test --exclude known_bug

  Not covered: real concurrency races and multi-node lease checks (the Ecto
  sandbox serialises everything on one connection).
  """
  use SuperPi.DataCase, async: false
  use Oban.Testing, repo: SuperPi.Repo.active_repo()

  import ExUnit.CaptureLog

  alias SuperPi.Durable.{DeferredFlusher, Doc, Storage, TaskEngine}
  alias SuperPi.Durable.Schemas.{Conversation, Document, DocumentRevision, Entry}
  alias SuperPi.Durable.Schemas.Task, as: TaskSchema
  alias SuperPi.Workers.GenerationWakeWorker


  defp running_task(conv, opts \\ []) do
    {:ok, task} = TaskEngine.create_task(conv.id, "pi.generation", %{}, opts)
    {:ok, task} = TaskEngine.start_task(task.id)
    task
  end

  # Runs `fun`; returns {:ok, value} or {:raised, exception}.
  defp attempt(fun) do
    {:ok, fun.()}
  rescue
    e -> {:raised, e}
  end

  # Returns :accepted or :rejected for a DB write that a constraint should reject.
  defp insert_outcome(fun) do
    fun.()
    :accepted
  rescue
    _ -> :rejected
  end

  describe "deferred_flusher.ex" do
    test "a failing periodic flush is logged, not silently swallowed (:61-69)" do
      conv = Storage.create_conversation!()
      DeferredFlusher.stage_deferred("conversation", conv.id, "pi.live", %{"bad" => {:not, :json}})

      log =
        capture_log(fn ->
          send(Process.whereis(DeferredFlusher), :flush_tick)
          :sys.get_state(DeferredFlusher)
        end)

      assert log =~ "flush", "periodic flush failed (staged value is not JSON) but nothing was logged"
    end

    test "stage_deferred does not query the database (:24-30)" do
      parent = self()
      id = "stage-deferred-query-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        id,
        [:super_pi, :repo, :sq_lite, :query],
        fn _event, _m, meta, _cfg -> send(parent, {:repo_query, meta[:query]}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(id) end)

      DeferredFlusher.stage_deferred("conversation", 1, "pi.live", %{"a" => 1})

      refute_received {:repo_query, _}, "stage_deferred hits the DB on every call (Storage.current_seq)"
    end
  end

  describe "task_engine.ex create_task / wait_for_children" do
    test "create_task for a non-existent conversation returns {:error, _} instead of raising (:26-64)" do
      assert {:ok, {:error, _}} = attempt(fn -> TaskEngine.create_task(999_999, "pi.generation") end)
    end

    test "wait_for_children rejects unknown child ids instead of treating them as terminal (:396-401)" do
      conv = Storage.create_conversation!()
      parent = running_task(conv)

      assert {:error, _} = TaskEngine.wait_for_children(parent.id, [999_999])
    end
  end

  describe "stale wake jobs (task_engine.ex:99-130, oban_workers.ex:10-17)" do
    test "an old wake job does not wake a task that re-slept with a later deadline" do
      conv = Storage.create_conversation!()
      task = running_task(conv)

      early = DateTime.add(DateTime.utc_now(), 30, :second)
      {:ok, _} = TaskEngine.sleep_until(task.id, early)
      [old_job] = all_enqueued(worker: GenerationWakeWorker)

      {:ok, _} = TaskEngine.wake_sleeping_task(task.id)
      {:ok, _} = TaskEngine.start_task(task.id)
      late = DateTime.add(DateTime.utc_now(), 3600, :second)
      {:ok, sleeping} = TaskEngine.sleep_until(task.id, late)
      assert sleeping.status == "sleeping"

      perform_job(GenerationWakeWorker, old_job.args)

      assert Repo.get!(TaskSchema, task.id).status == "sleeping",
             "stale job for the earlier deadline woke the task before its new deadline"
    end
  end

  describe "reconcile_on_open! (task_engine.ex:214-268)" do
    test "recovers a waiting parent whose children are all terminal" do
      conv = Storage.create_conversation!()
      parent = running_task(conv)
      {:ok, child} = TaskEngine.create_task(conv.id, "pi.child", %{}, owner_task_id: parent.id)
      {:ok, _} = TaskEngine.wait_for_children(parent.id, [child.id])

      # Crash window: the child settled but the parent was never woken.
      Repo.update!(Ecto.Changeset.change(child, status: "completed"))

      TaskEngine.reconcile_on_open!(conv.id)

      assert Repo.get!(TaskSchema, parent.id).status != "waiting",
             "parent stays waiting forever on already-settled children"
    end

    test "recovers a completing task whose children have settled" do
      conv = Storage.create_conversation!()
      parent = running_task(conv)
      {:ok, child} = TaskEngine.create_task(conv.id, "pi.child", %{}, owner_task_id: parent.id)
      {:ok, completing} = TaskEngine.complete_task(parent.id, %{"ok" => true})
      assert completing.status == "completing"

      Repo.update!(Ecto.Changeset.change(child, status: "completed"))

      TaskEngine.reconcile_on_open!(conv.id)

      assert Repo.get!(TaskSchema, parent.id).status == "completed",
             "completing task is never completed after its children settled"
    end
  end

  describe "abort_task! (task_engine.ex:198-206,310-340)" do
    test "a missing task id returns {:error, :not_found} instead of raising" do
      assert {:ok, {:error, :not_found}} = attempt(fn -> TaskEngine.abort_task!(999_999) end)
    end

    test "aborting a completing target sets abort_requested on it" do
      conv = Storage.create_conversation!()
      parent = running_task(conv)
      {:ok, _child} = TaskEngine.create_task(conv.id, "pi.child", %{}, owner_task_id: parent.id)
      {:ok, %{status: "completing"}} = TaskEngine.complete_task(parent.id, %{"ok" => true})

      TaskEngine.abort_task!(parent.id)

      assert Repo.get!(TaskSchema, parent.id).abort_requested == true,
             "child settling completes the target first; abort_requested is never recorded"
    end
  end

  describe "schema constraints (migration, doc.ex:73-90)" do
    defp new_doc!(attrs \\ %{}) do
      %Document{}
      |> Document.changeset(
        Map.merge(
          %{
            kind: "k.unique",
            key: "",
            scope_kind: "conversation",
            scope_id: 77,
            history_policy: "latest",
            fork_policy: "initial",
            created_seq: 1
          },
          attrs
        )
      )
      |> Repo.insert!()
    end

    test "two active documents with the same (scope_kind, scope_id, kind, key) are rejected" do
      new_doc!()
      assert :rejected == insert_outcome(fn -> new_doc!() end)
    end

    test "two revisions of one document with the same seq are rejected" do
      doc = new_doc!()

      rev = fn ->
        %DocumentRevision{}
        |> DocumentRevision.changeset(%{document_id: doc.id, seq: 5, version: 1, is_checkpoint_base: true, value: %{}})
        |> Repo.insert!()
      end

      rev.()
      assert :rejected == insert_outcome(rev)
    end

    test "two entries of one conversation with the same seq are rejected" do
      conv = Storage.create_conversation!()

      entry = fn ->
        %Entry{}
        |> Entry.changeset(%{conversation_id: conv.id, seq: 9_000, kind: "pi.message", data: %{}})
        |> Repo.insert!()
      end

      entry.()
      assert :rejected == insert_outcome(entry)
    end

    test "entries.head_entry_id must reference an existing entry" do
      conv = Storage.create_conversation!()

      assert :rejected ==
               insert_outcome(fn ->
                 %Entry{}
                 |> Entry.changeset(%{conversation_id: conv.id, seq: 9_001, kind: "k", head_entry_id: 999_999, data: %{}})
                 |> Repo.insert!()
               end)
    end

    test "conversations.parent_entry_id must reference an existing entry" do
      assert :rejected ==
               insert_outcome(fn ->
                 %Conversation{}
                 |> Conversation.changeset(%{parent_entry_id: 999_999, owner_kind: "ownerless", created_seq: 1})
                 |> Repo.insert!()
               end)
    end

    test "conversations.owner_task_id must reference an existing task" do
      assert :rejected ==
               insert_outcome(fn ->
                 %Conversation{}
                 |> Conversation.changeset(%{owner_task_id: 999_999, owner_kind: "task", created_seq: 1})
                 |> Repo.insert!()
               end)
    end
  end

  describe "doc.ex" do
    test "apply_ops does not silently swallow a corrupt patch (:245-251)" do
      conv = Storage.create_conversation!()
      opts = [history_policy: "rewindable", checkpoint_every: 100]

      Storage.commit(fn seq -> Doc.put_doc("conversation", conv.id, "x.rewind", %{"a" => 1}, seq, opts) end)

      doc = Repo.one!(from d in Document, where: d.scope_id == ^conv.id and d.kind == "x.rewind")

      Repo.insert!(%DocumentRevision{
        document_id: doc.id,
        seq: Storage.current_seq() + 1,
        version: 1,
        is_checkpoint_base: false,
        ops: %{"ops" => [%{"op" => "replace", "path" => "/missing/deep", "value" => 2}]}
      })

      :ets.delete_all_objects(:super_pi_doc_cache)

      result = attempt(fn -> Doc.snapshot("conversation", conv.id, "x.rewind") end)

      refute result == {:ok, %{"a" => 1}},
             "corrupt patch ignored; stale base returned as if it were current"
    end

    test "latest-policy documents keep a bounded revision history (:62-110)" do
      conv = Storage.create_conversation!()

      for i <- 1..30 do
        Storage.commit(fn seq -> Doc.put_doc("conversation", conv.id, "pi.live", %{"status" => "s#{i}"}, seq) end)
      end

      doc = Repo.one!(from d in Document, where: d.scope_id == ^conv.id and d.kind == "pi.live")
      count = length(Repo.all(from r in DocumentRevision, where: r.document_id == ^doc.id))

      assert count <= 3, "latest doc accumulated #{count} revisions for 30 writes"
    end
  end

  describe "storage.ex fork_conversation! (:130-157)" do
    test "forking at an entry that belongs to another conversation is rejected" do
      a = Storage.create_conversation!()
      b = Storage.create_conversation!()
      foreign = Storage.append_entry!(b.id, "pi.message", %{"role" => "user", "content" => "x"})

      result = attempt(fn -> Storage.fork_conversation!(a.id, foreign.id) end)

      refute match?({:ok, %Conversation{}}, result), "fork created from a foreign conversation's entry"
    end
  end

  describe "config" do

    test "sum of Oban queue limits does not exceed the SQLite pool size" do
      cfg = Config.Reader.read!(Path.join(config_dir(), "config.exs"), env: :dev, target: :host)
      limits = cfg |> get_in([:super_pi, Oban, :queues]) |> Keyword.values() |> Enum.sum()
      pool = get_in(cfg, [:super_pi, SuperPi.Repo.SQLite, :pool_size])

      assert limits <= pool, "queue limits sum to #{limits}, pool_size is #{pool}"
    end

    test "SQLite repo defaults to immediate transactions" do
      cfg = Config.Reader.read!(Path.join(config_dir(), "config.exs"), env: :dev, target: :host)

      assert get_in(cfg, [:super_pi, SuperPi.Repo.SQLite, :default_transaction_mode]) == :immediate,
             "deferred read-then-write transactions can hit SQLITE_BUSY"
    end

    test ".gitignore covers SQLite journal files" do
      root = Path.expand("../../..", __DIR__)

      for f <- ["priv/x.db-journal", "priv/x.db-shm", "priv/x.db-wal"] do
        {_, code} = System.cmd("git", ["check-ignore", "-q", f], cd: root)
        assert code == 0, "#{f} is not ignored"
      end
    end
  end

  describe "cluster.ex" do
    test "moduledoc names the env var that runtime.exs reads" do
      {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(SuperPi.Cluster)
      runtime = File.read!(Path.join(config_dir(), "runtime.exs"))

      assert runtime =~ "SUPER_PI_STORAGE_BACKEND"
      refute doc =~ "SUPER_PI_DB_ADAPTER", "moduledoc documents an env var nothing reads"
    end

    test "Cluster.status does not report cluster_ready? when no cluster process is supervised" do
      previous = Application.get_env(:super_pi, :storage_backend)
      Application.put_env(:super_pi, :storage_backend, :postgres)
      on_exit(fn -> Application.put_env(:super_pi, :storage_backend, previous) end)

      ready? = SuperPi.Cluster.status().cluster_ready?

      children = Supervisor.which_children(SuperPi.Supervisor) |> Enum.map(&elem(&1, 0))

      cluster_supervised? =
        Enum.any?(children, fn id -> inspect(id) =~ ~r/Horde|Cluster\.Supervisor/ end)

      refute ready? and not cluster_supervised?,
             "cluster_ready? is true but no libcluster/Horde child is supervised"
    end
  end

  defp config_dir, do: Path.expand("../../../config", __DIR__)
end
