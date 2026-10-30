defmodule SuperPi.Durable.DurableDefectsTest do
  @moduledoc """
  Regression tests that reproduce durable-layer defects found in the code review
  (see vault note "20 - Codebase Review Findings"). Every test is expected to
  FAIL on the current code and pass once the matching finding is fixed.

  Run only these:  mix test --only known_bug
  Skip these:      mix test --exclude known_bug

  Not covered here: races that need real concurrent transactions (abort vs
  complete, concurrent `next_seq!`). The Ecto sandbox runs in shared mode and
  serialises all work on one connection, so those need a non-sandbox DB test.
  """
  use SuperPi.DataCase, async: false

  alias SuperPi.Durable.{DeferredFlusher, Doc, Storage, TaskEngine}
  alias SuperPi.Durable.Schemas.Task, as: TaskSchema

  @usage_scope {"conversation", "pi.usage"}

  defp running_task(conv, opts \\ []) do
    {:ok, task} = TaskEngine.create_task(conv.id, "pi.generation", %{}, opts)
    {:ok, task} = TaskEngine.start_task(task.id)
    task
  end

  defp running_child(conv, parent) do
    running_task(conv, owner_task_id: parent.id)
  end

  defp stage_usage(conv, input_tokens) do
    {scope_kind, kind} = @usage_scope

    DeferredFlusher.stage_deferred(scope_kind, conv.id, kind, %{
      "inputTokens" => input_tokens,
      "outputTokens" => 0,
      "costUsd" => 0.0
    })
  end

  describe "C4: deferred data is deleted before it is persisted (deferred_flusher.ex:44, storage.ex:223)" do
    test "flush_now! keeps staged data when the DB write fails" do
      conv = Storage.create_conversation!()

      # A tuple cannot be JSON-encoded, so the DB write must fail.
      DeferredFlusher.stage_deferred("conversation", conv.id, "pi.live", %{"bad" => {:not, :json}})

      assert DeferredFlusher.pending_count() == 1

      raised? =
        try do
          DeferredFlusher.flush_now!()
          false
        rescue
          _ -> true
        end

      assert raised?, "precondition: flush_now! must fail on a non-encodable value"

      assert DeferredFlusher.pending_count() == 1,
             "staged data was deleted from ETS although the DB write failed"
    end

    test "a rolled-back commit does not discard staged deferred data" do
      conv = Storage.create_conversation!()
      stage_usage(conv, 7)
      assert DeferredFlusher.pending_count() == 1

      assert_raise RuntimeError, "boom", fn ->
        Storage.commit(fn _seq -> raise "boom" end)
      end

      assert DeferredFlusher.pending_count() == 1,
             "commit drained the pending table, then rolled back; the staged data is lost"
    end

    test "staged data is flushed when the flusher is shut down" do
      conv = Storage.create_conversation!()

      # Take over from the application's flusher so a periodic tick cannot flush first.
      :ok = Supervisor.terminate_child(SuperPi.Supervisor, DeferredFlusher)
      Process.flag(:trap_exit, true)

      try do
        {:ok, pid} = DeferredFlusher.start_link(flush_interval_ms: 600_000)
        ref = Process.monitor(pid)

        stage_usage(conv, 42)

        # This is what a supervisor does on shutdown.
        Process.exit(pid, :shutdown)
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000

        # Drop caches so the read comes from the database.
        :ets.delete_all_objects(:super_pi_doc_cache)
        :ets.delete_all_objects(:super_pi_deferred_pending)

        assert %{"inputTokens" => 42} = Doc.snapshot("conversation", conv.id, "pi.usage"),
               "up to one flush interval of staged state is lost on shutdown (no trap_exit / terminate/2)"
      after
        Supervisor.restart_child(SuperPi.Supervisor, DeferredFlusher)
      end
    end
  end

  describe "C5: doc cache is written inside the transaction and never rolled back (doc.ex:108-119)" do
    test "snapshot does not serve a value from a rolled-back commit" do
      conv = Storage.create_conversation!()
      assert Doc.snapshot("conversation", conv.id, "pi.live") == %{"status" => "idle"}

      assert_raise RuntimeError, "boom", fn ->
        Storage.commit(fn seq ->
          Doc.put_doc("conversation", conv.id, "pi.live", %{"status" => "phantom"}, seq)
          raise "boom"
        end)
      end

      assert Doc.snapshot("conversation", conv.id, "pi.live") == %{"status" => "idle"},
             "snapshot returned a value that was never persisted"
    end
  end

  describe "task engine: lost wakeup for parents waiting on children (task_engine.ex:85-93)" do
    test "wait_for_children on children that already completed does not leave the parent waiting" do
      conv = Storage.create_conversation!()
      parent = running_task(conv)
      child = running_child(conv, parent)
      {:ok, _} = TaskEngine.complete_task(child.id, %{})

      {:ok, parent_after} = TaskEngine.wait_for_children(parent.id, [child.id])

      refute parent_after.status == "waiting",
             "parent waits on a child that already settled; nothing will ever wake it"
    end

    test "wait_for_children with an empty child list does not leave the parent waiting" do
      conv = Storage.create_conversation!()
      parent = running_task(conv)

      {:ok, parent_after} = TaskEngine.wait_for_children(parent.id, [])

      refute parent_after.status == "waiting"
    end
  end

  describe "task engine: state transitions are too permissive (task_engine.ex:70-82)" do
    test "start_task on an already running task is rejected" do
      conv = Storage.create_conversation!()
      task = running_task(conv)

      assert {:error, _} = TaskEngine.start_task(task.id),
             "a second worker can claim a task that is already running"
    end

    test "checkpoint_task on a waiting task is rejected" do
      conv = Storage.create_conversation!()
      parent = running_task(conv)

      {:ok, pending_child} =
        TaskEngine.create_task(conv.id, "child", %{}, owner_task_id: parent.id)

      {:ok, waiting} = TaskEngine.wait_for_children(parent.id, [pending_child.id])
      assert waiting.status == "waiting"

      assert {:error, _} = TaskEngine.checkpoint_task(parent.id, "phase2", %{}),
             "checkpoint flipped a waiting task back to running and skipped its wait condition"
    end
  end

  describe "task engine: terminal operations are not idempotent (task_engine.ex:150-191)" do
    test "complete_task called twice returns the settled task, not a changeset error" do
      conv = Storage.create_conversation!()
      task = running_task(conv)

      assert {:ok, %TaskSchema{status: "completed"}} =
               TaskEngine.complete_task(task.id, %{"v" => 1})

      assert {:ok, %TaskSchema{status: "completed"}} =
               TaskEngine.complete_task(task.id, %{"v" => 1}),
             "a worker retry cannot tell 'already done' from a real failure"
    end

    test "fail_task aborts live foreground children instead of orphaning them" do
      conv = Storage.create_conversation!()
      parent = running_task(conv)
      child = running_child(conv, parent)

      {:ok, _} = TaskEngine.fail_task(parent.id, %{"error" => "boom"})

      child_after = Repo.get!(TaskSchema, child.id)

      assert child_after.status in ["aborted", "cancelled"],
             "child is still #{child_after.status} under a failed parent"
    end
  end

  describe "seq allocation (task_engine.ex:273-294, storage.ex:45-66)" do
    test "transition_task allocates a distinct updated_seq per transition" do
      conv = Storage.create_conversation!()
      {:ok, a} = TaskEngine.create_task(conv.id, "pi.generation")
      {:ok, b} = TaskEngine.create_task(conv.id, "pi.generation")

      {:ok, a_running} = TaskEngine.start_task(a.id)
      {:ok, b_running} = TaskEngine.start_task(b.id)

      refute a_running.updated_seq == b_running.updated_seq,
             "two transitions share updated_seq #{a_running.updated_seq}"
    end

    test "next_seq! never returns a value already used as a task updated_seq" do
      conv = Storage.create_conversation!()
      {:ok, task} = TaskEngine.create_task(conv.id, "pi.generation")
      {:ok, running} = TaskEngine.start_task(task.id)

      assert Storage.next_seq!() > running.updated_seq,
             "transition_task used current_seq + 1 without incrementing the counter"
    end

    test "the migration seeds the global_seq row" do
      %{rows: [[count]]} =
        Repo.query!("SELECT count(*) FROM record_ids WHERE name = 'global_seq'")

      assert count == 1,
             "next_seq! relies on an INSERT-on-first-use fallback that races on Postgres"
    end
  end
end
