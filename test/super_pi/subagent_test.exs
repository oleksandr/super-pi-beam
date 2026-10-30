defmodule SuperPi.SubagentTest do
  @moduledoc """
  delegate_subagent starts child conversations and returns at once (Task 35, Part 4 of the plan).

  Oban runs in `testing: :manual`, so a test runs the children with `drain/0`. The child machines
  get their `llm_responder` from `config :super_pi, :subagent_machine_opts`.
  """
  use SuperPi.DataCase, async: false

  import Ecto.Query

  alias SuperPi.Auth
  alias SuperPi.Conversation.{Locator, Machine}
  alias SuperPi.Durable.{Context, Doc, Storage, TaskEngine}
  alias SuperPi.Durable.Schemas.Conversation
  alias SuperPi.Durable.Schemas.Task, as: TaskSchema
  alias SuperPi.Plugins.Subagent
  alias SuperPi.TestSupport.Faults

  defp parent!(agent \\ %{}) do
    base = %{
      "model" => "test-model",
      "executionMode" => "accept-edits",
      "workspacePaths" => [File.cwd!()]
    }

    Storage.create_conversation!(agent: Map.merge(base, agent))
  end

  defp parent_task!(conv) do
    {:ok, task} = TaskEngine.create_task(conv.id, "pi.generation")
    {:ok, running} = TaskEngine.start_task(task.id)
    running
  end

  # The children's model, for every child machine this test starts.
  defp children_respond!(responder) do
    Application.put_env(:super_pi, :subagent_machine_opts, llm_responder: responder)
    on_exit(fn -> Application.delete_env(:super_pi, :subagent_machine_opts) end)
  end

  # Calls the tool as the machine does, inside a running parent task.
  defp delegate(conv, args, extra_ctx \\ %{}) do
    task_id = Map.get_lazy(extra_ctx, :active_task_id, fn -> parent_task!(conv).id end)
    ctx = Map.merge(%{conversation_id: conv.id, active_task_id: task_id}, extra_ctx)
    Subagent.wrap_tool("delegate_subagent", args, fn _ -> %{} end, ctx)
  end

  defp drain, do: Oban.drain_queue(queue: :subagents)

  defp text(t), do: fn _p, _c -> {:ok, Faults.text_msg(t)} end

  # Responder that reports the request it received.
  defp spy(me, reply \\ "done") do
    fn payload, _ctx ->
      send(me, {:payload, payload})
      {:ok, Faults.text_msg(reply)}
    end
  end

  # Tells the test it runs, then waits for `:release`.
  defp blocking(me, reply \\ "released") do
    fn payload, _ctx ->
      send(me, {:child_running, self(), inspect(payload.messages)})

      receive do
        :release -> {:ok, Faults.text_msg(reply)}
      after
        15_000 -> {:error, "never released"}
      end
    end
  end

  # Jobs of this test. Other runs on a shared database (the cluster tests) leave finished ones.
  defp queued_jobs,
    do:
      Repo.all(
        from(j in Oban.Job,
          where: j.worker == "SuperPi.Workers.SubagentWorker" and j.state == "available",
          order_by: j.id
        )
      )

  defp subagent_tasks,
    do: Repo.all(from(t in TaskSchema, where: t.kind == "pi.subagent", order_by: t.id))

  defp task_status(id), do: Repo.get!(TaskSchema, id).status
  defp children(res), do: res["structured_output"]["subagents"]

  defp registered_machines,
    do: Enum.map(Locator.all(), fn {id, _pid} -> {:conversation_machine, id} end)

  defp eventually(fun, tries \\ 300) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never held")
      true -> Process.sleep(10) && eventually(fun, tries - 1)
    end
  end

  defp machine_state(pid), do: pid |> Machine.get_state() |> elem(0)

  describe "a delegated task" do
    test "returns an acknowledgement at once, before any child runs" do
      conv = parent!()
      task = parent_task!(conv)

      res =
        delegate(conv, %{"role" => "scout", "prompt" => "find the router"}, %{
          active_task_id: task.id
        })

      refute res["is_error"]
      assert res["output"] =~ "acknowledgement"

      assert [%{"status" => "started", "child_conversation_id" => child_id, "task_id" => task_id}] =
               children(res)

      assert res["output"] =~ "child conversation #{child_id}"

      # The control directive tells the machine to park, on these tasks.
      assert %{"await" => %{"task_ids" => [^task_id], "policy" => "all_settled"}} = res["control"]

      # No child ran: its task waits for a job, the parent waits for the child.
      assert [%{id: ^task_id, status: "pending"}] = subagent_tasks()
      assert task_status(task.id) == "waiting"
      assert Locator.whereis(child_id) == nil

      assert [%{worker: "SuperPi.Workers.SubagentWorker", queue: "subagents", max_attempts: 1}] =
               queued_jobs()
    end

    test "the child runs in its job and its answer is the task's summary" do
      children_respond!(text("The router is in lib/router.ex"))
      conv = parent!()
      res = delegate(conv, %{"role" => "scout", "prompt" => "find the router"})
      [%{"task_id" => task_id}] = children(res)

      assert %{success: 1, failure: 0} = drain()

      task = Repo.get!(TaskSchema, task_id)
      assert task.status == "completed"
      assert task.result["summary"] =~ "lib/router.ex"
    end

    test "a child's job that finds its task aborted does nothing" do
      children_respond!(text("never"))
      conv = parent!()

      [%{"task_id" => task_id, "child_conversation_id" => child_id}] =
        conv |> delegate(%{"role" => "scout", "prompt" => "x"}) |> children()

      TaskEngine.abort_task!(task_id)
      assert %{success: 1} = drain()

      assert task_status(task_id) == "aborted"
      assert Locator.whereis(child_id) == nil
      assert Context.derive(child_id).messages == []
    end

    test "the child prompt is exactly the task, and the child has a role prompt" do
      children_respond!(spy(self()))
      conv = parent!()
      delegate(conv, %{"role" => "reviewer", "prompt" => "review the diff"})
      drain()

      assert_received {:payload, payload}
      assert inspect(payload.messages) =~ "review the diff"
      assert Enum.any?(payload.system_sections, &(&1["content"] =~ "reviewer"))
    end

    test "is recorded as a child conversation owned by a child task of the parent's task" do
      children_respond!(text("ok"))
      conv = parent!()
      task = parent_task!(conv)

      res = delegate(conv, %{"role" => "worker", "prompt" => "do it"}, %{active_task_id: task.id})
      [%{"child_conversation_id" => child_id}] = children(res)
      drain()

      child = Repo.get!(Conversation, child_id)
      assert child.owner_kind == "task"
      assert child.owner_task_id == task.id

      [record] = subagent_tasks()
      assert record.owner_task_id == task.id
      assert record.conversation_id == conv.id
      assert record.status == "completed"
      assert record.input["child_conversation_id"] == child_id
    end

    test "the child belongs to the parent's owner" do
      Application.put_env(:super_pi, :gateway_tokens, alice: "tok")
      on_exit(fn -> Application.delete_env(:super_pi, :gateway_tokens) end)

      conv = parent!()
      Auth.claim!(conv.id, "alice")

      [%{"child_conversation_id" => child_id}] =
        conv |> delegate(%{"role" => "scout", "prompt" => "x"}) |> children()

      assert Auth.owner(child_id) == "alice"
    end

    test "no machine is left running" do
      children_respond!(text("ok"))
      before = registered_machines()
      conv = parent!()
      delegate(conv, %{"role" => "scout", "prompt" => "x"})
      drain()
      assert registered_machines() -- before == []
    end

    test "a delegation without a running turn is refused" do
      conv = parent!()

      res =
        Subagent.wrap_tool(
          "delegate_subagent",
          %{"role" => "scout", "prompt" => "x"},
          fn _ -> %{} end,
          %{conversation_id: conv.id}
        )

      assert res["structured_output"]["status"] == "invalid_context"
    end

    test "a second delegation while children run is refused" do
      conv = parent!()
      task = parent_task!(conv)
      delegate(conv, %{"role" => "scout", "prompt" => "one"}, %{active_task_id: task.id})

      res = delegate(conv, %{"role" => "scout", "prompt" => "two"}, %{active_task_id: task.id})

      assert res["is_error"]
      assert res["structured_output"]["status"] == "already_delegating"
      assert length(subagent_tasks()) == 1
    end
  end

  describe "events" do
    test "subagent_started and subagent_finished go to the parent conversation" do
      children_respond!(text("found it"))
      conv = parent!()
      Phoenix.PubSub.subscribe(SuperPi.PubSub, "conversation:#{conv.id}")
      task = parent_task!(conv)

      [%{"child_conversation_id" => child_id}] =
        conv
        |> delegate(%{"role" => "scout", "prompt" => "look"}, %{active_task_id: task.id})
        |> children()

      drain()

      assert_receive {:conversation_event, _,
                      %{
                        "type" => "subagent_started",
                        "child_conversation_id" => ^child_id,
                        "role" => "scout",
                        "task" => "look",
                        "turn_id" => turn
                      }}

      assert turn == task.id

      assert_receive {:conversation_event, _,
                      %{
                        "type" => "subagent_finished",
                        "child_conversation_id" => ^child_id,
                        "status" => "completed",
                        "summary" => "found it"
                      }}
    end

    test "a failed child is reported as failed" do
      children_respond!(fn _p, _c -> {:error, "boom"} end)
      conv = parent!()
      Phoenix.PubSub.subscribe(SuperPi.PubSub, "conversation:#{conv.id}")
      delegate(conv, %{"role" => "scout", "prompt" => "x"})
      drain()

      assert_receive {:conversation_event, _,
                      %{"type" => "subagent_finished", "status" => "failed", "summary" => summary}}

      assert summary =~ "boom"
    end
  end

  describe "permissions of the child" do
    defp child_agent(res) do
      [%{"child_conversation_id" => id}] = children(res)
      Doc.snapshot("conversation", id, "pi.agent")
    end

    test "read-only roles run in plan mode with read-only tools" do
      for role <- ["scout", "planner", "reviewer", "researcher"] do
        conv = parent!(%{"executionMode" => "auto"})
        agent = conv |> delegate(%{"role" => role, "prompt" => "x"}) |> child_agent()

        assert agent["executionMode"] == "plan"
        names = Enum.map(agent["tools"], & &1["name"])

        assert names -- ["read", "grep", "find", "ls", "tool_search"] == [],
               "#{role}: #{inspect(names)}"
      end
    end

    test "a read-only child has a ceiling of plan, so no setting can lift it" do
      conv = parent!(%{"executionMode" => "auto"})
      agent = conv |> delegate(%{"role" => "scout", "prompt" => "x"}) |> child_agent()
      assert agent["maxExecutionMode"] == "plan"
    end

    test "a worker never gets a ceiling above its parent's" do
      conv = parent!(%{"executionMode" => "accept-edits", "maxExecutionMode" => "accept-edits"})
      agent = conv |> delegate(%{"role" => "worker", "prompt" => "x"}) |> child_agent()
      assert agent["maxExecutionMode"] == "accept-edits"
    end

    test "a worker inherits the parent's mode and never gains it" do
      for mode <- ["plan", "accept-edits", "auto"] do
        conv = parent!(%{"executionMode" => mode})
        agent = conv |> delegate(%{"role" => "worker", "prompt" => "x"}) |> child_agent()
        assert agent["executionMode"] == mode
      end
    end

    test "permission settings and the skip flag are copied, not raised" do
      settings = %{"permissions" => %{"deny" => ["command(curl)"]}}
      conv = parent!(%{"settingsOverride" => settings})
      agent = conv |> delegate(%{"role" => "worker", "prompt" => "x"}) |> child_agent()

      assert agent["settingsOverride"] == settings
      assert agent["dangerouslySkipPermissions"] == false
    end

    test "a child has no delegate, question or handoff tool" do
      conv = parent!(%{"executionMode" => "auto"})
      agent = conv |> delegate(%{"role" => "worker", "prompt" => "x"}) |> child_agent()
      names = Enum.map(agent["tools"], & &1["name"])

      for tool <- ["delegate_subagent", "ask_question", "handoff"], do: refute(tool in names)
      assert "read" in names
    end

    test "the child uses the parent's model and workspace" do
      conv = parent!(%{"model" => "special-model"})
      agent = conv |> delegate(%{"role" => "worker", "prompt" => "x"}) |> child_agent()
      assert agent["model"] == "special-model"
      assert agent["workspacePaths"] == [File.cwd!()]
    end
  end

  describe "limits" do
    test "a subagent cannot delegate further" do
      conv = parent!(%{"subagentDepth" => 1})
      res = delegate(conv, %{"role" => "scout", "prompt" => "x"})

      assert res["is_error"]
      assert res["structured_output"]["status"] == "depth_limit"
    end

    test "the depth limit is configurable" do
      Application.put_env(:super_pi, :subagent_max_depth, 2)
      on_exit(fn -> Application.delete_env(:super_pi, :subagent_max_depth) end)

      conv = parent!(%{"subagentDepth" => 1})
      refute delegate(conv, %{"role" => "scout", "prompt" => "x"})["is_error"]
    end

    test "a child that exceeds the timeout is failed and stopped" do
      children_respond!(fn _p, _c -> Process.sleep(3_000) && {:ok, Faults.text_msg("late")} end)
      before = registered_machines()
      conv = parent!()

      [%{"task_id" => task_id}] =
        conv |> delegate(%{"role" => "scout", "prompt" => "x", "timeout_ms" => 200}) |> children()

      drain()

      task = Repo.get!(TaskSchema, task_id)
      assert task.status == "failed"
      assert task.result["error"] =~ "timed out"
      assert registered_machines() -- before == []
    end

    test "the model may shorten the timeout but not raise it" do
      conv = parent!()
      Application.put_env(:super_pi, :subagent_timeout_ms, 1_000)
      on_exit(fn -> Application.delete_env(:super_pi, :subagent_timeout_ms) end)

      delegate(conv, %{"role" => "scout", "prompt" => "x", "timeout_ms" => 999_000})
      assert [%{args: %{"timeout_ms" => 1_000}}] = queued_jobs()
    end

    test "a failing child's task record is failed with its error" do
      children_respond!(fn _p, _c -> {:error, "boom"} end)
      conv = parent!()
      delegate(conv, %{"role" => "scout", "prompt" => "x"})
      drain()

      assert [%{status: "failed", result: %{"error" => error}}] = subagent_tasks()
      assert error =~ "boom"
    end

    test "a long answer is truncated" do
      children_respond!(text(String.duplicate("a", 20_000)))
      conv = parent!()
      delegate(conv, %{"role" => "scout", "prompt" => "x"})
      drain()

      [%{result: %{"summary" => summary}}] = subagent_tasks()
      assert summary =~ "[truncated]"
      assert byte_size(summary) < 9_000
    end
  end

  describe "several tasks" do
    test "start together under one wait, each with its own job" do
      conv = parent!()
      task = parent_task!(conv)
      tasks = for i <- 1..3, do: %{"role" => "scout", "prompt" => "task #{i}"}

      res = delegate(conv, %{"tasks" => tasks}, %{active_task_id: task.id})

      assert length(children(res)) == 3
      assert length(queued_jobs()) == 3
      assert res["control"]["await"]["task_ids"] == Enum.map(subagent_tasks(), & &1.id)

      parent = Repo.get!(TaskSchema, task.id)
      assert parent.status == "waiting"
      assert parent.waiting_on_task_ids["ids"] == Enum.map(subagent_tasks(), & &1.id)
    end

    test "one failure does not hide the others" do
      children_respond!(fn payload, _ctx ->
        if inspect(payload.messages) =~ "bad",
          do: {:error, "nope"},
          else: {:ok, Faults.text_msg("good result")}
      end)

      conv = parent!()

      delegate(conv, %{
        "tasks" => [
          %{"role" => "scout", "prompt" => "bad one"},
          %{"role" => "scout", "prompt" => "fine"}
        ]
      })

      drain()

      assert [%{status: "failed"}, %{status: "completed", result: %{"summary" => "good result"}}] =
               subagent_tasks()
    end
  end

  describe "arguments" do
    test "bad arguments are rejected before any child starts" do
      conv = parent!()

      for args <- [
            %{},
            %{"role" => "scout"},
            %{"role" => "wizard", "prompt" => "x"},
            %{"role" => "scout", "prompt" => "   "},
            %{"tasks" => []},
            %{"tasks" => ["oops"]},
            %{"tasks" => [%{"role" => "scout", "prompt" => 5}]},
            %{"role" => "scout", "prompt" => "x", "wait_policy" => "whenever"}
          ] do
        res = delegate(conv, args)

        assert res["structured_output"]["status"] == "invalid_arguments",
               "args #{inspect(args)}: #{inspect(res)}"
      end

      assert Repo.all(from(c in Conversation, where: c.owner_kind == "task")) == []
      assert queued_jobs() == []
    end

    test "a call without a conversation context is an error, not a crash" do
      res =
        Subagent.wrap_tool(
          "delegate_subagent",
          %{"role" => "scout", "prompt" => "x"},
          fn _ -> %{} end,
          %{}
        )

      assert res["structured_output"]["status"] == "invalid_context"
    end

    test "the tool description tells the model that the answers come later" do
      description = Subagent.tool_spec()["description"]
      assert description =~ "does not wait"
      assert description =~ "separate message"
    end
  end

  # The parent's machine, driven by a scripted model: it delegates once, then answers.
  describe "through the parent conversation" do
    defp parent_responder(me, delegation) do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      fn payload, _ctx ->
        case Agent.get_and_update(calls, &{&1, &1 + 1}) do
          0 ->
            {:ok, Faults.tool_call_msg("d1", "delegate_subagent", delegation)}

          _ ->
            send(me, {:history, payload.messages})
            {:ok, Faults.text_msg("all done")}
        end
      end
    end

    defp start_parent(conv, responder) do
      {:ok, pid} =
        Machine.start_link(
          conversation_id: conv.id,
          extensions: [{Subagent, []}],
          llm_responder: responder
        )

      pid
    end

    defp submit_async(pid, text),
      do: Task.async(fn -> Machine.safe_submit(pid, text, timeout: 30_000) end)

    defp user_texts(messages) do
      for %{"role" => "user", "content" => [%{"text" => t} | _]} <- messages, do: t
    end

    defp generation_task(conv),
      do:
        Repo.one!(
          from(t in TaskSchema,
            where: t.conversation_id == ^conv.id and t.kind == "pi.generation"
          )
        )

    test "the model delegates, the machine parks, and the summaries arrive as the next messages" do
      children_respond!(text("The router lives in lib/router.ex"))
      conv = parent!(%{"executionMode" => "auto"})

      pid =
        start_parent(
          conv,
          parent_responder(self(), %{"role" => "scout", "prompt" => "where is the router?"})
        )

      sub = submit_async(pid, "delegate please")
      eventually(fn -> machine_state(pid) == :awaiting_children end)
      assert task_status(generation_task(conv).id) == "waiting"

      drain()
      assert {:ok, _} = Task.await(sub, 10_000)

      assert_received {:history, history}
      # The tool call has one result: the acknowledgement. The answer is a separate message.
      assert [%{"content" => ack}] = Enum.filter(history, &(&1["role"] == "tool"))
      assert ack =~ "acknowledgement"
      refute ack =~ "lib/router.ex"

      assert Enum.any?(
               user_texts(history),
               &(&1 =~ "Subagent scout" and &1 =~ "finished" and &1 =~ "lib/router.ex")
             )

      assert task_status(generation_task(conv).id) == "completed"
    end

    test "the parent wakes at once when the child ends: a message, not the poll" do
      Application.put_env(:super_pi, :await_poll_ms, 600_000)
      on_exit(fn -> Application.delete_env(:super_pi, :await_poll_ms) end)

      children_respond!(text("quick"))
      conv = parent!(%{"executionMode" => "auto"})
      pid = start_parent(conv, parent_responder(self(), %{"role" => "scout", "prompt" => "x"}))

      sub = submit_async(pid, "go")
      eventually(fn -> machine_state(pid) == :awaiting_children end)
      drain()

      assert {:ok, _} = Task.await(sub, 5_000)
    end

    test "the parent answers get_state, compact and a queued submit while children run" do
      me = self()
      children_respond!(blocking(me))
      conv = parent!(%{"executionMode" => "auto"})
      pid = start_parent(conv, parent_responder(me, %{"role" => "scout", "prompt" => "slow"}))

      sub = submit_async(pid, "go")
      eventually(fn -> machine_state(pid) == :awaiting_children end)
      runner = Task.async(&drain/0)
      assert_receive {:child_running, child_pid, _}, 5_000

      assert {:awaiting_children, data} = Machine.get_state(pid)
      assert data.active_task_id
      assert {:ok, _} = Machine.compact(pid, timeout: 2_000)
      assert {:ok, %{mode: :write}} = Machine.submit(pid, "a note", mode: :write)
      assert machine_state(pid) == :awaiting_children

      send(child_pid, :release)
      assert {:ok, _} = Task.await(sub, 10_000)
      Task.await(runner, 10_000)
    end

    test "cancel while children run stops the turn, the tasks and the child's machine" do
      me = self()
      children_respond!(blocking(me))
      conv = parent!(%{"executionMode" => "auto"})
      pid = start_parent(conv, parent_responder(me, %{"role" => "scout", "prompt" => "slow"}))

      sub = submit_async(pid, "go")
      eventually(fn -> machine_state(pid) == :awaiting_children end)
      runner = Task.async(&drain/0)
      assert_receive {:child_running, child_llm, _}, 5_000
      [%{id: sub_task_id, input: %{"child_conversation_id" => child_id}}] = subagent_tasks()
      assert is_pid(Locator.whereis(child_id))

      Machine.cancel(pid)

      assert {:error, :cancelled} = Task.await(sub, 5_000)
      assert machine_state(pid) == :idle
      assert task_status(generation_task(conv).id) == "cancelled"
      assert task_status(sub_task_id) == "aborted"
      eventually(fn -> Locator.whereis(child_id) == nil end)
      refute Process.alive?(child_llm)
      Task.await(runner, 10_000)
    end

    test "session.cancel aborts the whole subtree, also the children that have not started" do
      me = self()
      children_respond!(blocking(me))
      conv = parent!(%{"executionMode" => "auto"})

      delegation = %{
        "tasks" => [
          %{"role" => "scout", "prompt" => "first"},
          %{"role" => "worker", "prompt" => "second"}
        ]
      }

      pid = start_parent(conv, parent_responder(me, delegation))

      sub = submit_async(pid, "go")
      eventually(fn -> machine_state(pid) == :awaiting_children end)
      # The drain runs the jobs one after the other: the first child runs, the second is queued.
      runner = Task.async(&drain/0)
      assert_receive {:child_running, _, _}, 5_000
      [first, second] = subagent_tasks()
      assert task_status(first.id) == "running"
      assert task_status(second.id) == "pending"

      Machine.cancel(pid)
      assert {:error, :cancelled} = Task.await(sub, 5_000)

      assert Enum.map(subagent_tasks(), & &1.status) == ["aborted", "aborted"]
      assert Repo.get!(TaskSchema, first.id).abort_requested
      assert Repo.get!(TaskSchema, second.id).abort_requested

      # The queued job starts after the abort and does nothing.
      assert %{success: 2} = Task.await(runner, 10_000)
      refute_received {:child_running, _, _}
      assert Locator.whereis(second.input["child_conversation_id"]) == nil
      assert Context.derive(second.input["child_conversation_id"]).messages == []
    end

    test "wait_policy all: the parent waits for the slow child after a failure" do
      me = self()

      children_respond!(fn payload, ctx ->
        if inspect(payload.messages) =~ "bad",
          do: {:error, "boom"},
          else: blocking(me, "slow result").(payload, ctx)
      end)

      conv = parent!(%{"executionMode" => "auto"})

      delegation = %{
        "tasks" => [
          %{"role" => "scout", "prompt" => "bad"},
          %{"role" => "scout", "prompt" => "slow"}
        ]
      }

      pid = start_parent(conv, parent_responder(me, delegation))

      sub = submit_async(pid, "go")
      eventually(fn -> machine_state(pid) == :awaiting_children end)
      runner = Task.async(&drain/0)
      assert_receive {:child_running, slow_pid, _}, 5_000
      assert [%{status: "failed"}, %{status: "running"}] = subagent_tasks()

      Process.sleep(200)
      assert machine_state(pid) == :awaiting_children
      assert task_status(generation_task(conv).id) == "waiting"

      send(slow_pid, :release)
      assert {:ok, _} = Task.await(sub, 10_000)
      Task.await(runner, 10_000)

      assert_received {:history, history}
      texts = user_texts(history)
      assert Enum.any?(texts, &(&1 =~ "failed: " and &1 =~ "boom"))
      assert Enum.any?(texts, &(&1 =~ "slow result"))
    end

    test "wait_policy fail_fast: a failure wakes the parent at once and the others are stopped" do
      me = self()

      children_respond!(fn payload, ctx ->
        if inspect(payload.messages) =~ "bad",
          do: {:error, "boom"},
          else: blocking(me).(payload, ctx)
      end)

      conv = parent!(%{"executionMode" => "auto"})

      delegation = %{
        "wait_policy" => "fail_fast",
        "tasks" => [
          %{"role" => "scout", "prompt" => "bad"},
          %{"role" => "scout", "prompt" => "slow"}
        ]
      }

      pid = start_parent(conv, parent_responder(me, delegation))

      sub = submit_async(pid, "go")
      eventually(fn -> machine_state(pid) == :awaiting_children end)
      runner = Task.async(&drain/0)

      # The slow child is never released: the turn ends because the failure woke the parent.
      assert {:ok, _} = Task.await(sub, 10_000)
      Task.await(runner, 10_000)

      assert_received {:history, history}
      texts = user_texts(history)
      assert Enum.any?(texts, &(&1 =~ "failed: " and &1 =~ "boom"))
      assert Enum.any?(texts, &(&1 =~ "did not finish (aborted)"))
      assert [%{status: "failed"}, %{status: "aborted"}] = subagent_tasks()
      assert task_status(generation_task(conv).id) == "completed"
    end

    test "a parked parent is parked again by a new machine, and goes on when the child ends" do
      children_respond!(text("answer"))
      conv = parent!(%{"executionMode" => "auto"})
      me = self()
      responder = parent_responder(me, %{"role" => "scout", "prompt" => "x"})
      pid = start_parent(conv, responder)

      spawn(fn -> Machine.safe_submit(pid, "go", timeout: 30_000) end)
      eventually(fn -> machine_state(pid) == :awaiting_children end)

      # The machine is lost, as with its node.
      :gen_statem.stop(pid)
      Locator.await_gone(conv.id)

      {:ok, pid2} =
        Machine.start_link(
          conversation_id: conv.id,
          extensions: [{Subagent, []}],
          llm_responder: responder
        )

      eventually(fn -> machine_state(pid2) == :awaiting_children end)
      assert task_status(generation_task(conv).id) == "waiting"

      drain()

      eventually(fn -> task_status(generation_task(conv).id) == "completed" end)
      assert_received {:history, history}
      assert Enum.any?(user_texts(history), &(&1 =~ "answer"))
    end

    test "children that end while no parent machine runs are found when it starts" do
      children_respond!(text("answer"))
      conv = parent!(%{"executionMode" => "auto"})
      me = self()
      responder = parent_responder(me, %{"role" => "scout", "prompt" => "x"})
      pid = start_parent(conv, responder)

      spawn(fn -> Machine.safe_submit(pid, "go", timeout: 30_000) end)
      eventually(fn -> machine_state(pid) == :awaiting_children end)
      :gen_statem.stop(pid)
      Locator.await_gone(conv.id)

      drain()
      assert task_status(generation_task(conv).id) == "pending"

      {:ok, _pid2} =
        Machine.start_link(
          conversation_id: conv.id,
          extensions: [{Subagent, []}],
          llm_responder: responder
        )

      eventually(fn -> task_status(generation_task(conv).id) == "completed" end)
      assert_received {:history, history}
      assert Enum.any?(user_texts(history), &(&1 =~ "answer"))
    end

    test "a child whose job was lost is settled by its own machine when the turn resumes" do
      # The job's node died while the child ran: its task is running, its turn pending, no machine.
      children_respond!(text("resumed answer"))
      conv = parent!()
      task = parent_task!(conv)

      [%{"task_id" => sub_task_id, "child_conversation_id" => child_id}] =
        conv
        |> delegate(%{"role" => "scout", "prompt" => "x"}, %{active_task_id: task.id})
        |> children()

      {:ok, _} = TaskEngine.start_task(sub_task_id)

      Storage.append_entry!(child_id, "pi.message", %{
        "role" => "user",
        "content" => [%{"type" => "text", "text" => "x"}]
      })

      {:ok, gen} = TaskEngine.create_task(child_id, "pi.generation", %{"prompt" => "x"})
      {:ok, _} = TaskEngine.start_task(gen.id)

      Repo.update_all(from(t in TaskSchema, where: t.id == ^gen.id),
        set: [owner_node: "dead@127.0.0.1"]
      )

      {:ok, pid} =
        Locator.ensure_started(child_id, SuperPi.Workers.SubagentWorker.machine_opts("scout"))

      eventually(fn -> task_status(sub_task_id) == "completed" end)
      assert Repo.get!(TaskSchema, sub_task_id).result["summary"] == "resumed answer"
      # Nobody waits for this machine, so it stops itself.
      eventually(fn -> not Process.alive?(pid) end)
      assert task_status(task.id) == "pending"
    end
  end
end
