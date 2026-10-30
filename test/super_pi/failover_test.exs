defmodule SuperPi.FailoverTest do
  @moduledoc """
  A machine that starts after a crash or a node failure resumes the turn that was running.
  (The multi-node version of this is in `test/super_pi/cluster_test.exs`.)
  """
  use SuperPi.DataCase, async: false

  import Ecto.Query

  alias SuperPi.Conversation.{Locator, Machine}
  alias SuperPi.Durable.{Storage, TaskEngine}
  alias SuperPi.Durable.Schemas.{Entry, Task}
  alias SuperPi.TestSupport.Faults

  # A conversation with a user message and a generation task that was running on `owner_node`.
  defp interrupted(owner_node) do
    conv = Storage.create_conversation!(agent: %{"model" => "m"})

    Storage.append_entry!(conv.id, "pi.message", %{
      "role" => "user",
      "content" => [%{"type" => "text", "text" => "finish this"}]
    })

    {:ok, task} = TaskEngine.create_task(conv.id, "pi.generation", %{"prompt" => "finish this"})
    {:ok, _} = TaskEngine.start_task(task.id)
    Repo.update_all(from(t in Task, where: t.id == ^task.id), set: [owner_node: owner_node])
    {conv, task}
  end

  defp start(conv, extra \\ []) do
    me = self()

    responder = fn payload, _ctx ->
      send(me, {:responder, inspect(payload.messages)})
      {:ok, Faults.text_msg("resumed answer")}
    end

    opts = [extensions: [], llm_responder: responder] ++ extra
    {:ok, pid} = Locator.ensure_started(conv.id, opts, restart: :temporary, supervision: :local)
    pid
  end

  defp await_status(task_id, status, tries \\ 100) do
    task = Repo.get!(Task, task_id)

    cond do
      task.status == status -> task
      tries == 0 -> flunk("task #{task_id} is #{task.status}, expected #{status}")
      true -> Process.sleep(50) && await_status(task_id, status, tries - 1)
    end
  end

  defp assistant_texts(conv) do
    Repo.all(
      from(e in Entry,
        where: e.conversation_id == ^conv.id and e.kind == "pi.message",
        order_by: [asc: e.seq]
      )
    )
    |> Enum.map(& &1.data)
    |> Enum.filter(&(&1["role"] == "assistant"))
    |> Enum.flat_map(& &1["content"])
    |> Enum.map(& &1["text"])
  end

  test "start_task records the node" do
    conv = Storage.create_conversation!()
    {:ok, task} = TaskEngine.create_task(conv.id, "pi.generation")
    {:ok, running} = TaskEngine.start_task(task.id)
    assert running.owner_node == Atom.to_string(node())
  end

  test "a running task of this node (a crashed machine) is resumed and completed" do
    {conv, task} = interrupted(Atom.to_string(node()))
    start(conv)

    done = await_status(task.id, "completed")
    assert done.attempt == 1
    assert assistant_texts(conv) == ["resumed answer"]
    assert_received {:responder, messages}
    assert messages =~ "finish this"
  end

  test "a task of a node that is gone is resumed" do
    {conv, task} = interrupted("ghost@nowhere.invalid")
    start(conv)
    await_status(task.id, "completed")
    assert assistant_texts(conv) == ["resumed answer"]
  end

  test "a task with no recorded owner (older data) is resumed" do
    {conv, task} = interrupted(nil)
    start(conv)
    await_status(task.id, "completed")
  end

  test "a task that was already pending is resumed" do
    conv = Storage.create_conversation!()

    Storage.append_entry!(conv.id, "pi.message", %{
      "role" => "user",
      "content" => [%{"type" => "text", "text" => "q"}]
    })

    {:ok, task} = TaskEngine.create_task(conv.id, "pi.generation", %{"prompt" => "q"})
    start(conv)
    await_status(task.id, "completed")
  end

  test "a task over its restart limit fails instead of looping" do
    {conv, task} = interrupted(Atom.to_string(node()))
    Repo.update_all(from(t in Task, where: t.id == ^task.id), set: [attempt: 5, restart_limit: 5])
    start(conv)

    failed = await_status(task.id, "failed")
    assert failed.result["error"] == "restart_limit_exceeded"
    assert assistant_texts(conv) == []
  end

  test "resuming can be turned off" do
    Application.put_env(:super_pi, :resume_pending_turns, false)
    on_exit(fn -> Application.delete_env(:super_pi, :resume_pending_turns) end)

    {conv, task} = interrupted(Atom.to_string(node()))
    start(conv)
    Process.sleep(300)

    assert Repo.get!(Task, task.id).status == "pending"
    assert assistant_texts(conv) == []
  end

  test "a child task is not resumed as a turn" do
    conv = Storage.create_conversation!()
    {:ok, parent} = TaskEngine.create_task(conv.id, "pi.generation")
    {:ok, _} = TaskEngine.start_task(parent.id)
    {:ok, child} = TaskEngine.create_task(conv.id, "pi.generation", %{}, owner_task_id: parent.id)

    refute TaskEngine.next_pending_generation(conv.id) &&
             TaskEngine.next_pending_generation(conv.id).id == child.id
  end

  test "after the resumed turn the conversation takes new input" do
    {conv, task} = interrupted(Atom.to_string(node()))
    pid = start(conv)
    await_status(task.id, "completed")

    assert {:ok, _} = Machine.submit(pid, "and now this", timeout: 10_000)
    assert assistant_texts(conv) == ["resumed answer", "resumed answer"]
  end
end
