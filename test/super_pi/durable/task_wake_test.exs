defmodule SuperPi.Durable.TaskWakeTest do
  @moduledoc "A parent that waits on its children is woken, announced, cancelled and recovered (non-blocking delegation)."
  use SuperPi.DataCase, async: false

  alias SuperPi.Conversation.Locator
  alias SuperPi.Durable.{Storage, TaskEngine}
  alias SuperPi.Durable.Schemas.Task, as: TaskSchema

  defp setup_family(policy \\ "all_settled", count \\ 2) do
    conv = Storage.create_conversation!()
    {:ok, task} = TaskEngine.create_task(conv.id, "pi.generation")
    {:ok, parent} = TaskEngine.start_task(task.id)

    children =
      for _ <- 1..count do
        {:ok, child} = TaskEngine.create_task(conv.id, "pi.subagent", %{}, owner_task_id: parent.id)
        {:ok, running} = TaskEngine.start_task(child.id)
        running
      end

    {:ok, waiting} = TaskEngine.wait_for_children(parent.id, Enum.map(children, & &1.id), policy, phase: "awaiting_children", state: %{"children" => [%{"task_id" => 1}]})
    %{conv: conv, parent: waiting, children: children}
  end

  # Stands in for the machine of the conversation: `Locator.whereis/1` finds this process.
  defp register_as_machine(conv) do
    {:ok, _} = Horde.Registry.register(Locator.registry(), Locator.key(conv.id), nil)
    on_exit(fn -> Horde.Registry.unregister(Locator.registry(), Locator.key(conv.id)) end)
  end

  defp status(id), do: Repo.get!(TaskSchema, id).status

  test "wait_for_children checkpoints the phase and state with the move to waiting" do
    %{parent: parent} = setup_family()
    assert parent.status == "waiting"
    assert parent.phase == "awaiting_children"
    assert parent.state == %{"children" => [%{"task_id" => 1}], "phase" => "awaiting_children"}
  end

  test "the last child to settle wakes the parent and the conversation's machine is told" do
    %{conv: conv, parent: parent, children: [a, b]} = setup_family()
    register_as_machine(conv)

    TaskEngine.complete_task(a.id, %{})
    assert status(parent.id) == "waiting"
    refute_received {:task_woken, _}

    TaskEngine.complete_task(b.id, %{})
    assert status(parent.id) == "pending"
    assert_received {:task_woken, parent_id}
    assert parent_id == parent.id
  end

  test "fail_fast: one failure wakes the parent at once, and says which child failed" do
    %{conv: conv, parent: parent, children: [a, _b]} = setup_family("fail_fast")
    register_as_machine(conv)

    TaskEngine.fail_task(a.id, "boom")

    woken = Repo.get!(TaskSchema, parent.id)
    assert woken.status == "pending"
    assert woken.state["failedChildId"] == a.id
    assert_received {:task_woken, _}
  end

  test "a conversation without a machine is not an error" do
    %{parent: parent, children: [a, b]} = setup_family()
    TaskEngine.complete_task(a.id, %{})
    TaskEngine.complete_task(b.id, %{})
    assert status(parent.id) == "pending"
  end

  test "cancelling a waiting parent aborts its children and ends it cancelled" do
    %{parent: parent, children: children} = setup_family()

    assert {:ok, %{status: "cancelled"}} = TaskEngine.cancel_task(parent.id, %{"reason" => "cancelled"})

    assert Enum.map(children, &status(&1.id)) == ["aborted", "aborted"]
    assert Enum.all?(children, &Repo.get!(TaskSchema, &1.id).abort_requested)
  end

  test "aborting a waiting parent aborts its children" do
    %{parent: parent, children: children} = setup_family()
    TaskEngine.abort_task!(parent.id)
    assert status(parent.id) == "aborted"
    assert Enum.map(children, &status(&1.id)) == ["aborted", "aborted"]
  end

  describe "reconcile_on_open!/1 of a parked parent" do
    test "leaves it waiting while a child runs" do
      %{conv: conv, parent: parent} = setup_family()
      TaskEngine.reconcile_on_open!(conv.id)
      assert status(parent.id) == "waiting"
      assert TaskEngine.next_waiting_generation(conv.id).id == parent.id
    end

    test "makes it pending when its children ended while no machine ran" do
      %{conv: conv, parent: parent, children: children} = setup_family()
      Enum.each(children, &Repo.update!(Ecto.Changeset.change(&1, status: "completed")))
      TaskEngine.reconcile_on_open!(conv.id)

      assert status(parent.id) == "pending"
      assert TaskEngine.next_waiting_generation(conv.id) == nil
      assert TaskEngine.next_pending_generation(conv.id).phase == "awaiting_children"
    end

    test "makes a fail_fast parent pending when one child failed" do
      %{conv: conv, parent: parent, children: [a, _]} = setup_family("fail_fast")
      Repo.update!(Ecto.Changeset.change(a, status: "failed"))
      TaskEngine.reconcile_on_open!(conv.id)
      assert status(parent.id) == "pending"
    end
  end
end
