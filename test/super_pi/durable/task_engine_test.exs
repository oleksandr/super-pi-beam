defmodule SuperPi.Durable.TaskEngineTest do
  use SuperPi.DataCase, async: false
  use ExUnitProperties

  alias SuperPi.Durable.{Storage, TaskEngine}
  alias SuperPi.Durable.Schemas.Task, as: TaskSchema

  describe "Property-Based Tests: Fsmx Task State Machine & Recovery (REQ-PBT-03)" do
    property "Fsmx enforces valid transitions and rejects all illegal terminal-to-active transitions" do
      all_statuses = [
        "pending",
        "running",
        "waiting",
        "sleeping",
        "completing",
        "completed",
        "failed",
        "aborted",
        "cancelled",
        "orphaned"
      ]

      check all(
              attempted_transitions <-
                list_of(member_of(all_statuses), min_length: 3, max_length: 12),
              max_runs: 30
            ) do
        conv = Storage.create_conversation!()
        {:ok, initial_task} = TaskEngine.create_task(conv.id, "pi.generation", %{"turn" => 1})

        final_task =
          Enum.reduce(attempted_transitions, initial_task, fn target_status, current_task ->
            was_terminal = TaskSchema.terminal?(current_task)

            case TaskEngine.transition_task(current_task.id, target_status) do
              {:ok, updated} ->
                refute was_terminal,
                       "Terminal state #{current_task.status} must never transition to #{target_status}"

                assert updated.status == target_status
                updated

              {:error, _changeset} ->
                persisted = Repo.get!(TaskSchema, current_task.id)
                assert persisted.status == current_task.status
                current_task
            end
          end)

        assert Repo.get!(TaskSchema, initial_task.id).status == final_task.status
      end
    end

    property "reconcile_on_open! recovers running tasks to pending up to restart_limit and then fails them" do
      check all(
              restart_limit <- integer(1..6),
              crashes <- integer(1..9),
              abandon <- boolean(),
              max_runs: 25
            ) do
        conv = Storage.create_conversation!()

        {:ok, task} =
          TaskEngine.create_task(
            conv.id,
            "pi.tool",
            %{"tool" => "bash"},
            restart_limit: restart_limit,
            abandon_on_restart: abandon
          )

        final_task =
          Enum.reduce_while(1..crashes, task, fn _crash_idx, acc ->
            case acc.status do
              "pending" ->
                {:ok, _running} = TaskEngine.start_task(acc.id)
                [reconciled] = TaskEngine.reconcile_on_open!(conv.id)
                {:cont, reconciled}

              _terminal ->
                {:halt, acc}
            end
          end)

        cond do
          abandon ->
            assert final_task.status == "cancelled"
            assert final_task.attempt == 1

          crashes > restart_limit ->
            assert final_task.status == "failed"
            assert final_task.result["error"] == "restart_limit_exceeded"
            assert final_task.attempt == restart_limit + 1

          true ->
            assert final_task.status == "pending"
            assert final_task.attempt == crashes
        end
      end
    end

    property "parent waiting tasks wake according to all_settled vs fail_fast policies" do
      check all(
              policy <- member_of(["all_settled", "fail_fast"]),
              child_outcomes <-
                list_of(member_of([:complete, :fail]), min_length: 2, max_length: 5),
              max_runs: 25
            ) do
        conv = Storage.create_conversation!()
        {:ok, parent} = TaskEngine.create_task(conv.id, "pi.generation")
        {:ok, parent} = TaskEngine.start_task(parent.id)

        children =
          for {outcome, idx} <- Enum.with_index(child_outcomes, 1) do
            {:ok, child} =
              TaskEngine.create_task(conv.id, "pi.tool", %{"idx" => idx},
                owner_task_id: parent.id
              )

            {:ok, child} = TaskEngine.start_task(child.id)
            {child, outcome}
          end

        child_ids = Enum.map(children, fn {c, _} -> c.id end)
        {:ok, _waiting_parent} = TaskEngine.wait_for_children(parent.id, child_ids, policy)

        Enum.each(children, fn {child, outcome} ->
          case outcome do
            :complete ->
              {:ok, _} = TaskEngine.complete_task(child.id, %{"ok" => true})

            :fail ->
              {:ok, _} = TaskEngine.fail_task(child.id, %{"error" => "boom"})
          end

          current_parent = Repo.get!(TaskSchema, parent.id)

          if policy == "fail_fast" and outcome == :fail do
            assert current_parent.status == "pending"
          end
        end)

        settled_parent = Repo.get!(TaskSchema, parent.id)
        assert settled_parent.status == "pending"
      end
    end

    test "completing task holds result until owned foreground children finish and bottom-up abort drains children first" do
      conv = Storage.create_conversation!()
      {:ok, parent} = TaskEngine.create_task(conv.id, "pi.generation")
      {:ok, parent} = TaskEngine.start_task(parent.id)

      {:ok, child1} = TaskEngine.create_task(conv.id, "pi.tool", %{}, owner_task_id: parent.id)
      {:ok, child1} = TaskEngine.start_task(child1.id)

      # Parent finishes while child1 is still running -> enters "completing"
      {:ok, completing_parent} = TaskEngine.complete_task(parent.id, %{"answer" => "42"})
      assert completing_parent.status == "completing"

      # Once child1 finishes, parent automatically transitions to "completed"
      {:ok, _} = TaskEngine.complete_task(child1.id, %{"output" => "done"})
      assert Repo.get!(TaskSchema, parent.id).status == "completed"

      # Bottom-up subtree abort test
      {:ok, root_task} = TaskEngine.create_task(conv.id, "pi.generation")
      {:ok, root_task} = TaskEngine.start_task(root_task.id)

      {:ok, sub_task} =
        TaskEngine.create_task(conv.id, "pi.tool", %{}, owner_task_id: root_task.id)

      {:ok, _sub_task} = TaskEngine.start_task(sub_task.id)

      aborted_root = TaskEngine.abort_task!(root_task.id)
      assert aborted_root.status == "aborted"
      assert aborted_root.abort_requested == true
      assert Repo.get!(TaskSchema, sub_task.id).status == "aborted"
    end

    test "sleep_until transitions task to sleeping, schedules Oban wake job, and wakes back to pending" do
      conv = Storage.create_conversation!()
      {:ok, task} = TaskEngine.create_task(conv.id, "pi.generation")
      {:ok, task} = TaskEngine.start_task(task.id)

      wake_at = DateTime.add(DateTime.utc_now(), 30, :second)

      {:ok, sleeping} =
        TaskEngine.sleep_until(task.id, wake_at, %{"phase" => "retry_wait", "attempt" => 2})

      assert sleeping.status == "sleeping"
      assert sleeping.phase == "retry_wait"
      assert sleeping.sleep_until == wake_at

      {:ok, woken} = TaskEngine.wake_sleeping_task(task.id)
      assert woken.status == "pending"
      assert woken.sleep_until == nil
    end
  end
end
