defmodule SuperPi.Conversation.MachineDefectsTest do
  @moduledoc """
  Regression tests that reproduce defects found in the code review
  (see vault note "20 - Codebase Review Findings"). Every test is expected to
  FAIL on the current code and pass once the matching finding is fixed.

  Run only these:  mix test --only known_bug
  Skip these:      mix test --exclude known_bug
  """
  use SuperPi.DataCase, async: false

  import Ecto.Query

  alias SuperPi.Conversation.Machine
  alias SuperPi.Durable.Schemas.Task, as: TaskSchema
  alias SuperPi.Durable.Storage
  alias SuperPi.TestSupport.Faults

  @moduletag :known_bug

  setup do
    # Machines are linked to the test process. A machine crash must surface as
    # an assertion failure, not as a test-process exit.
    Process.flag(:trap_exit, true)
    :ok
  end

  defp submit(pid, text, timeout \\ 2_000) do
    Machine.submit(pid, text, timeout: timeout)
  catch
    :exit, reason -> {:exit, reason}
  end

  defp generation_tasks(conv_id) do
    Repo.all(from t in TaskSchema, where: t.conversation_id == ^conv_id and t.kind == "pi.generation")
  end

  describe "C1: terminate path sends :settle, which has no handler (machine.ex:351,367)" do
    test "tool result with control.terminate completes the run instead of crashing the machine" do
      conv = Storage.create_conversation!()

      {:ok, pid} =
        Machine.start_link(
          conversation_id: conv.id,
          llm_responder: Faults.tool_then_text_responder("any_tool", %{}, "unused"),
          tool_executor: &Faults.terminating_tool_executor/3
        )

      result = submit(pid, "run and terminate")

      assert {:ok, _reply} = result,
             "submit must return {:ok, _} after control.terminate, got: #{inspect(result)}"

      assert Process.alive?(pid), "machine crashed on terminate"
      assert {:idle, _} = Machine.get_state(pid)
    end

    test "after_tools returning :terminate completes the run instead of crashing the machine" do
      conv = Storage.create_conversation!()

      {:ok, pid} =
        Machine.start_link(
          conversation_id: conv.id,
          extensions: [Faults.TerminateAfterTools],
          llm_responder: Faults.tool_then_text_responder("any_tool", %{}, "unused"),
          tool_executor: &Faults.plain_tool_executor/3
        )

      result = submit(pid, "run")

      assert {:ok, _reply} = result, "got: #{inspect(result)}"
      assert Process.alive?(pid)
    end

    test "generation task is completed, not left running, after terminate" do
      conv = Storage.create_conversation!()

      {:ok, pid} =
        Machine.start_link(
          conversation_id: conv.id,
          llm_responder: Faults.tool_then_text_responder("any_tool", %{}, "unused"),
          tool_executor: &Faults.terminating_tool_executor/3
        )

      _ = submit(pid, "run and terminate")

      assert [%TaskSchema{status: "completed"}] = generation_tasks(conv.id)
    end

    test "machine accepts a follow-up submit after a terminated run" do
      conv = Storage.create_conversation!()

      # First turn terminates; second turn (no tool results yet in its payload) is plain text.
      responder = fn payload, _ctx ->
        user_count = Enum.count(payload.messages, &(&1["role"] == "user"))

        if user_count == 1 do
          {:ok, Faults.tool_call_msg("call_1", "any_tool", %{})}
        else
          {:ok, Faults.text_msg("second turn ok")}
        end
      end

      {:ok, pid} =
        Machine.start_link(
          conversation_id: conv.id,
          llm_responder: responder,
          tool_executor: &Faults.terminating_tool_executor/3
        )

      _ = submit(pid, "first")

      assert {:ok, %{"content" => [%{"text" => "second turn ok"}]}} = submit(pid, "second")
    end
  end

  describe "C3: LLM call blocks the machine, so calls cannot be served during a turn (machine.ex:257-309)" do
    setup do
      conv = Storage.create_conversation!()

      {:ok, pid} =
        Machine.start_link(
          conversation_id: conv.id,
          llm_responder: Faults.blocking_responder(self(), "released")
        )

      submitter = Task.async(fn -> Machine.submit(pid, "slow turn", timeout: 20_000) end)
      assert_receive {:responder_started, responder_pid}, 5_000

      on_exit(fn -> if Process.alive?(responder_pid), do: send(responder_pid, :release) end)

      %{conv: conv, pid: pid, responder_pid: responder_pid, submitter: submitter}
    end

    test "get_state answers within 1s while a turn is in flight", ctx do
      probe = Task.async(fn -> Machine.get_state(ctx.pid) end)
      reply = Task.yield(probe, 1_000)
      Task.shutdown(probe, :brutal_kill)

      send(ctx.responder_pid, :release)
      Task.await(ctx.submitter, 5_000)

      assert {:ok, {state, _data}} = reply,
             "get_state did not answer within 1s while a turn was running"

      assert state in [:preparing_request, :streaming_llm]
    end

    test "set_extensions answers within 1s while a turn is in flight", ctx do
      probe = Task.async(fn -> Machine.set_extensions(ctx.pid, []) end)
      reply = Task.yield(probe, 1_000)
      Task.shutdown(probe, :brutal_kill)

      send(ctx.responder_pid, :release)
      Task.await(ctx.submitter, 5_000)

      assert reply == {:ok, :ok},
             "set_extensions did not answer within 1s while a turn was running"
    end
  end

  describe "stray messages and events (machine.ex: no catch-all handle_event)" do
    test "unexpected :info message does not crash an idle machine" do
      conv = Storage.create_conversation!()
      {:ok, pid} = Machine.start_link(conversation_id: conv.id)
      assert {:idle, _} = Machine.get_state(pid)

      send(pid, :unexpected_message)

      # get_state is a synchronous call, so it also acts as a barrier for the send above.
      assert {:idle, _} = Machine.get_state(pid)
      assert Process.alive?(pid)
    end
  end

  describe "unprotected hooks and responder inside the machine (finding 10)" do
    test "raising responder ends the run with an error and keeps the machine alive" do
      conv = Storage.create_conversation!()

      {:ok, pid} =
        Machine.start_link(conversation_id: conv.id, llm_responder: Faults.raising_responder())

      result = submit(pid, "hello")

      assert {:error, _reason} = result, "got: #{inspect(result)}"
      assert Process.alive?(pid)
      assert [%TaskSchema{status: "failed"}] = generation_tasks(conv.id)
    end

    test "raising before_tool extension ends the run with an error and keeps the machine alive" do
      conv = Storage.create_conversation!()

      {:ok, pid} =
        Machine.start_link(
          conversation_id: conv.id,
          extensions: [Faults.RaiseBeforeTool],
          llm_responder: Faults.tool_then_text_responder("any_tool", %{}, "done"),
          tool_executor: &Faults.plain_tool_executor/3
        )

      result = submit(pid, "hello")

      assert match?({:ok, _}, result) or match?({:error, _}, result), "got: #{inspect(result)}"
      assert Process.alive?(pid)
    end

    test "raising after_response extension ends the run with an error and keeps the machine alive" do
      conv = Storage.create_conversation!()

      {:ok, pid} =
        Machine.start_link(
          conversation_id: conv.id,
          extensions: [Faults.RaiseAfterResponse],
          llm_responder: fn _p, _c -> {:ok, Faults.text_msg("hi")} end
        )

      result = submit(pid, "hello")

      assert match?({:ok, _}, result) or match?({:error, _}, result), "got: #{inspect(result)}"
      assert Process.alive?(pid)
    end

    test "after_tools returning an unknown shape does not crash the machine (finding 13/18)" do
      conv = Storage.create_conversation!()

      {:ok, pid} =
        Machine.start_link(
          conversation_id: conv.id,
          extensions: [Faults.BadAfterToolsReturn],
          llm_responder: Faults.tool_then_text_responder("any_tool", %{}, "done"),
          tool_executor: &Faults.plain_tool_executor/3
        )

      result = submit(pid, "hello")

      assert match?({:ok, _}, result) or match?({:error, _}, result), "got: #{inspect(result)}"
      assert Process.alive?(pid)
    end
  end

  describe "nil fields in provider responses (finding 11)" do
    test "assistant message with \"usage\" => nil does not crash the machine" do
      conv = Storage.create_conversation!()

      {:ok, pid} =
        Machine.start_link(
          conversation_id: conv.id,
          llm_responder: fn _p, _c -> {:ok, Map.put(Faults.text_msg("hi"), "usage", nil)} end
        )

      result = submit(pid, "hello")

      assert {:ok, _} = result, "got: #{inspect(result)}"
      assert Process.alive?(pid)
    end

    test "assistant message with \"content\" => nil does not crash the machine" do
      conv = Storage.create_conversation!()

      {:ok, pid} =
        Machine.start_link(
          conversation_id: conv.id,
          llm_responder: fn _p, _c -> {:ok, %{"role" => "assistant", "content" => nil}} end
        )

      result = submit(pid, "hello")

      assert match?({:ok, _}, result) or match?({:error, _}, result), "got: #{inspect(result)}"
      assert Process.alive?(pid)
    end
  end
end
