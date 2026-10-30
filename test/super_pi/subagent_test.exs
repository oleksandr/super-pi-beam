defmodule SuperPi.SubagentTest do
  @moduledoc "delegate_subagent runs a real child conversation (Task 35)."
  use SuperPi.DataCase, async: false

  import Ecto.Query

  alias SuperPi.Auth
  alias SuperPi.Conversation.Machine
  alias SuperPi.Durable.{Doc, Storage, TaskEngine}
  alias SuperPi.Durable.Schemas.Conversation
  alias SuperPi.Durable.Schemas.Task, as: TaskSchema
  alias SuperPi.Plugins.Subagent
  alias SuperPi.TestSupport.Faults

  defp parent!(agent \\ %{}) do
    base = %{"model" => "test-model", "executionMode" => "accept-edits", "workspacePaths" => [File.cwd!()]}
    Storage.create_conversation!(agent: Map.merge(base, agent))
  end

  defp parent_task!(conv) do
    {:ok, task} = TaskEngine.create_task(conv.id, "pi.generation")
    {:ok, running} = TaskEngine.start_task(task.id)
    running
  end

  defp delegate(conv, args, responder, extra_ctx \\ %{}) do
    ctx = Map.merge(%{conversation_id: conv.id, config: [machine_opts: [llm_responder: responder]]}, extra_ctx)
    Subagent.wrap_tool("delegate_subagent", args, fn _ -> %{} end, ctx)
  end

  defp text(t), do: fn _p, _c -> {:ok, Faults.text_msg(t)} end

  # Responder that reports the request it received.
  defp spy(me, reply \\ "done") do
    fn payload, _ctx ->
      send(me, {:payload, payload})
      {:ok, Faults.text_msg(reply)}
    end
  end

  defp registered_machines do
    Registry.select(SuperPi.Registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.filter(&match?({:conversation_machine, _}, &1))
  end

  describe "a delegated task" do
    test "runs the child's model loop and returns its final answer" do
      conv = parent!()
      res = delegate(conv, %{"role" => "scout", "prompt" => "find the router"}, text("The router is in lib/router.ex"))

      refute res["is_error"]
      assert res["output"] =~ "Subagent (scout) finished"
      assert res["output"] =~ "lib/router.ex"
      assert [%{"status" => "completed", "child_conversation_id" => child_id}] = res["structured_output"]["subagents"]
      assert is_integer(child_id)
    end

    test "the child prompt is exactly the task, and the child has a role prompt" do
      conv = parent!()
      delegate(conv, %{"role" => "reviewer", "prompt" => "review the diff"}, spy(self()))

      assert_received {:payload, payload}
      assert inspect(payload.messages) =~ "review the diff"
      assert Enum.any?(payload.system_sections, &(&1["content"] =~ "reviewer"))
    end

    test "is recorded as a child conversation owned by a child task of the parent's task" do
      conv = parent!()
      task = parent_task!(conv)

      res = delegate(conv, %{"role" => "worker", "prompt" => "do it"}, text("ok"), %{active_task_id: task.id})
      [%{"child_conversation_id" => child_id}] = res["structured_output"]["subagents"]

      child = Repo.get!(Conversation, child_id)
      assert child.owner_kind == "task"
      assert child.owner_task_id == task.id

      [record] = Repo.all(from t in TaskSchema, where: t.kind == "pi.subagent")
      assert record.owner_task_id == task.id
      assert record.status == "completed"
      assert record.input["child_conversation_id"] == child_id
    end

    test "the child belongs to the parent's owner" do
      Application.put_env(:super_pi, :gateway_tokens, alice: "tok")
      on_exit(fn -> Application.delete_env(:super_pi, :gateway_tokens) end)

      conv = parent!()
      Auth.claim!(conv.id, "alice")
      res = delegate(conv, %{"role" => "scout", "prompt" => "x"}, text("ok"))
      [%{"child_conversation_id" => child_id}] = res["structured_output"]["subagents"]

      assert Auth.owner(child_id) == "alice"
    end

    test "no machine is left running" do
      before = registered_machines()
      conv = parent!()
      delegate(conv, %{"role" => "scout", "prompt" => "x"}, text("ok"))
      assert registered_machines() -- before == []
    end
  end

  describe "permissions of the child" do
    defp child_agent(res) do
      [%{"child_conversation_id" => id}] = res["structured_output"]["subagents"]
      Doc.snapshot("conversation", id, "pi.agent")
    end

    test "read-only roles run in plan mode with read-only tools" do
      for role <- ["scout", "planner", "reviewer", "researcher"] do
        conv = parent!(%{"executionMode" => "auto"})
        agent = conv |> delegate(%{"role" => role, "prompt" => "x"}, text("ok")) |> child_agent()

        assert agent["executionMode"] == "plan"
        names = Enum.map(agent["tools"], & &1["name"])
        assert names -- ["read", "grep", "find", "ls", "tool_search"] == [], "#{role}: #{inspect(names)}"
      end
    end

    test "a worker inherits the parent's mode and never gains it" do
      for mode <- ["plan", "accept-edits", "auto"] do
        conv = parent!(%{"executionMode" => mode})
        agent = conv |> delegate(%{"role" => "worker", "prompt" => "x"}, text("ok")) |> child_agent()
        assert agent["executionMode"] == mode
      end
    end

    test "permission settings and the skip flag are copied, not raised" do
      settings = %{"permissions" => %{"deny" => ["command(curl)"]}}
      conv = parent!(%{"settingsOverride" => settings})
      agent = conv |> delegate(%{"role" => "worker", "prompt" => "x"}, text("ok")) |> child_agent()

      assert agent["settingsOverride"] == settings
      assert agent["dangerouslySkipPermissions"] == false
    end

    test "a child has no delegate, question or handoff tool" do
      conv = parent!(%{"executionMode" => "auto"})
      agent = conv |> delegate(%{"role" => "worker", "prompt" => "x"}, text("ok")) |> child_agent()
      names = Enum.map(agent["tools"], & &1["name"])

      for tool <- ["delegate_subagent", "ask_question", "handoff"], do: refute(tool in names)
      assert "read" in names
    end

    test "the child uses the parent's model and workspace" do
      conv = parent!(%{"model" => "special-model"})
      agent = conv |> delegate(%{"role" => "worker", "prompt" => "x"}, text("ok")) |> child_agent()
      assert agent["model"] == "special-model"
      assert agent["workspacePaths"] == [File.cwd!()]
    end
  end

  describe "limits" do
    test "a subagent cannot delegate further" do
      conv = parent!(%{"subagentDepth" => 1})
      res = delegate(conv, %{"role" => "scout", "prompt" => "x"}, text("ok"))

      assert res["is_error"]
      assert res["structured_output"]["status"] == "depth_limit"
    end

    test "the depth limit is configurable" do
      Application.put_env(:super_pi, :subagent_max_depth, 2)
      on_exit(fn -> Application.delete_env(:super_pi, :subagent_max_depth) end)

      conv = parent!(%{"subagentDepth" => 1})
      refute delegate(conv, %{"role" => "scout", "prompt" => "x"}, text("ok"))["is_error"]
    end

    test "a child that exceeds the timeout is failed and stopped" do
      before = registered_machines()
      conv = parent!()
      slow = fn _p, _c -> Process.sleep(3_000) && {:ok, Faults.text_msg("late")} end

      res = delegate(conv, %{"role" => "scout", "prompt" => "x", "timeout_ms" => 200}, slow)

      assert res["is_error"]
      assert [%{"status" => "failed", "error" => error}] = res["structured_output"]["subagents"]
      assert error =~ "timed out"
      assert registered_machines() -- before == []
    end

    test "a failing child is reported, and its task record is failed" do
      conv = parent!()
      task = parent_task!(conv)
      res = delegate(conv, %{"role" => "scout", "prompt" => "x"}, fn _p, _c -> {:error, "boom"} end, %{active_task_id: task.id})

      assert res["is_error"]
      assert res["output"] =~ ~r/failed: .*boom/
      assert [%{status: "failed"}] = Repo.all(from t in TaskSchema, where: t.kind == "pi.subagent")
    end

    test "a long answer is truncated" do
      conv = parent!()
      res = delegate(conv, %{"role" => "scout", "prompt" => "x"}, text(String.duplicate("a", 20_000)))
      assert res["output"] =~ "[truncated]"
      assert byte_size(res["output"]) < 9_000
    end
  end

  describe "several tasks" do
    test "run concurrently and come back in order" do
      conv = parent!()
      {:ok, counter} = Agent.start_link(fn -> %{now: 0, max: 0} end)

      responder = fn payload, _ctx ->
        Agent.update(counter, fn s -> %{s | now: s.now + 1, max: max(s.max, s.now + 1)} end)
        Process.sleep(300)
        Agent.update(counter, fn s -> %{s | now: s.now - 1} end)
        {:ok, Faults.text_msg("answer to " <> inspect(payload.messages) |> String.slice(0, 60))}
      end

      tasks = for i <- 1..3, do: %{"role" => "scout", "prompt" => "task #{i}"}
      {micros, res} = :timer.tc(fn -> delegate(conv, %{"tasks" => tasks}, responder) end)

      assert Agent.get(counter, & &1.max) >= 2
      assert div(micros, 1000) < 800, "three 300 ms tasks took #{div(micros, 1000)} ms, so they ran one after another"
      assert length(res["structured_output"]["subagents"]) == 3
      assert res["output"] |> String.split("Subagent (scout) finished") |> length() == 4
    end

    test "one failure does not hide the others" do
      conv = parent!()

      responder = fn payload, _ctx ->
        if inspect(payload.messages) =~ "bad", do: {:error, "nope"}, else: {:ok, Faults.text_msg("good result")}
      end

      res = delegate(conv, %{"tasks" => [%{"role" => "scout", "prompt" => "bad one"}, %{"role" => "scout", "prompt" => "fine"}]}, responder)

      assert [%{"status" => "failed"}, %{"status" => "completed"}] = res["structured_output"]["subagents"]
      assert res["output"] =~ "good result"
      refute res["is_error"]
      assert res["details"]["failed"] == 1
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
            %{"tasks" => [%{"role" => "scout", "prompt" => 5}]}
          ] do
        res = delegate(conv, args, text("never"))
        assert res["structured_output"]["status"] == "invalid_arguments", "args #{inspect(args)}: #{inspect(res)}"
      end

      assert Repo.all(from c in Conversation, where: c.owner_kind == "task") == []
    end

    test "a call without a conversation context is an error, not a crash" do
      res = Subagent.wrap_tool("delegate_subagent", %{"role" => "scout", "prompt" => "x"}, fn _ -> %{} end, %{})
      assert res["structured_output"]["status"] == "invalid_context"
    end
  end

  describe "through the parent conversation" do
    test "the model calls the tool and sees the child's answer" do
      conv = parent!(%{"executionMode" => "auto"})
      me = self()
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      parent_responder = fn payload, _ctx ->
        case Agent.get_and_update(calls, &{&1, &1 + 1}) do
          0 ->
            {:ok, Faults.tool_call_msg("d1", "delegate_subagent", %{"role" => "scout", "prompt" => "where is the router?"})}

          _ ->
            send(me, {:history, inspect(payload.messages)})
            {:ok, Faults.text_msg("done")}
        end
      end

      child_responder = text("The router lives in lib/router.ex")

      {:ok, pid} =
        Machine.start_link(
          conversation_id: conv.id,
          extensions: [{Subagent, [machine_opts: [llm_responder: child_responder]]}],
          llm_responder: parent_responder
        )

      assert {:ok, _} = Machine.submit(pid, "delegate please", timeout: 30_000)
      assert_received {:history, history}
      assert history =~ "Subagent (scout) finished"
      assert history =~ "lib/router.ex"
    end
  end
end
