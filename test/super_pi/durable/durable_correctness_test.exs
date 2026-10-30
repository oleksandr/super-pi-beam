defmodule SuperPi.Durable.DurableCorrectnessTest do
  @moduledoc """
  Regression tests for the durable-correctness fixes (doc 24 P0.2).

  The Ecto sandbox shares one connection, so the concurrency tests check the
  invariants (one winner, no lost wakeup, unique seqs) but cannot reproduce
  true PostgreSQL interleavings. Those belong in the `:postgres` tests.
  """
  use SuperPi.DataCase, async: false

  alias SuperPi.Durable.{DeferredFlusher, Doc, Storage, TaskEngine}
  alias SuperPi.Durable.Schemas.Task, as: TaskSchema

  describe "deferred drain and same-document commit" do
    test "a commit that rewrites a document with a pending deferred update does not collide" do
      conv = Storage.create_conversation!()

      DeferredFlusher.stage_deferred("conversation", conv.id, "pi.agent", %{"model" => "staged"})
      assert DeferredFlusher.pending_count() == 1

      assert %{"model" => "final"} = Storage.configure_agent!(conv.id, %{model: "final"})

      assert DeferredFlusher.pending_count() == 0
      assert %{"model" => "final"} = Doc.snapshot("conversation", conv.id, "pi.agent")
    end

    test "the drained revision keeps an earlier seq than the caller's write" do
      conv = Storage.create_conversation!()

      DeferredFlusher.stage_deferred("conversation", conv.id, "pi.live", %{
        "status" => "streaming"
      })

      Storage.commit(fn seq ->
        Doc.put_doc("conversation", conv.id, "pi.live", %{"status" => "idle"}, seq)
        seq
      end)

      :ets.delete_all_objects(:super_pi_doc_cache)
      assert %{"status" => "idle"} = Doc.snapshot("conversation", conv.id, "pi.live")
    end
  end

  describe "next_seq!/0" do
    test "is strictly increasing under concurrent callers" do
      seqs =
        1..40
        |> Task.async_stream(fn _ -> Storage.next_seq!() end, max_concurrency: 8, timeout: 10_000)
        |> Enum.map(fn {:ok, seq} -> seq end)

      assert length(Enum.uniq(seqs)) == 40
      assert Storage.current_seq() == Enum.max(seqs)
    end

    test "recovers when the counter row is missing" do
      Repo.query!("DELETE FROM record_ids WHERE name = 'global_seq'")
      assert Storage.next_seq!() == 1
      assert Storage.next_seq!() == 2
    end
  end

  describe "snapshot_as_of/4 fork boundary" do
    test "a fork does not see parent configuration written after the fork entry" do
      parent = Storage.create_conversation!(agent: %{"model" => "m0"})
      entry = Storage.append_entry!(parent.id, "message", %{"role" => "user", "content" => "hi"})

      Storage.configure_agent!(parent.id, %{model: "m1"})

      child = Storage.fork_conversation!(parent.id, entry.id)

      # Between the fork entry and the child's creation the parent changed.
      probe_seq = child.created_seq - 1
      assert probe_seq > entry.seq

      assert %{"model" => "m0"} = Doc.snapshot_as_of(child.id, "pi.agent", probe_seq)
      assert %{"model" => "m0"} = Doc.snapshot_as_of(child.id, "pi.agent", child.created_seq)
    end

    test "after the fork the child follows its own document" do
      parent = Storage.create_conversation!(agent: %{"model" => "m0"})
      entry = Storage.append_entry!(parent.id, "message", %{"role" => "user", "content" => "hi"})
      child = Storage.fork_conversation!(parent.id, entry.id)

      Storage.configure_agent!(child.id, %{model: "child"})
      later = Storage.current_seq()

      assert %{"model" => "child"} = Doc.snapshot_as_of(child.id, "pi.agent", later)
      assert %{"model" => "m0"} = Doc.snapshot_as_of(parent.id, "pi.agent", later)
    end
  end

  describe "task engine concurrency" do
    setup do
      conv = Storage.create_conversation!()
      %{conv: conv}
    end

    test "only one of several concurrent start_task calls wins", %{conv: conv} do
      {:ok, task} = TaskEngine.create_task(conv.id, "pi.generation")

      results =
        1..6
        |> Task.async_stream(fn _ -> TaskEngine.start_task(task.id) end,
          max_concurrency: 6,
          timeout: 10_000
        )
        |> Enum.map(fn {:ok, r} -> r end)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :already_running})) == 5
    end

    test "start_task on an unknown task returns :not_found" do
      assert {:error, :not_found} = TaskEngine.start_task(-1)
    end

    test "wait_for_children returns the parent unchanged when every child already settled", %{
      conv: conv
    } do
      {:ok, parent} = TaskEngine.create_task(conv.id, "parent")
      {:ok, child} = TaskEngine.create_task(conv.id, "child", %{}, owner_task_id: parent.id)
      {:ok, _} = TaskEngine.start_task(parent.id)
      {:ok, _} = TaskEngine.start_task(child.id)
      {:ok, _} = TaskEngine.complete_task(child.id, %{})

      assert {:ok, %TaskSchema{status: "running"}} =
               TaskEngine.wait_for_children(parent.id, [child.id])
    end

    test "a child that settles while the parent waits wakes the parent, with no lost wakeup", %{
      conv: conv
    } do
      for _ <- 1..25 do
        {:ok, parent} = TaskEngine.create_task(conv.id, "parent")
        {:ok, child} = TaskEngine.create_task(conv.id, "child", %{}, owner_task_id: parent.id)
        {:ok, _} = TaskEngine.start_task(parent.id)
        {:ok, _} = TaskEngine.start_task(child.id)

        [waiter, completer] =
          [
            fn -> TaskEngine.wait_for_children(parent.id, [child.id]) end,
            fn -> TaskEngine.complete_task(child.id, %{"ok" => true}) end
          ]
          |> Enum.map(&Task.async/1)
          |> Enum.map(&Task.await(&1, 10_000))

        assert {:ok, _} = waiter
        assert {:ok, _} = completer

        final = Repo.get!(TaskSchema, parent.id)

        refute final.status == "waiting",
               "parent stuck in waiting although its only child settled"
      end
    end
  end
end
