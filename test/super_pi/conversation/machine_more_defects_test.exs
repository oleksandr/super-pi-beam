defmodule SuperPi.Conversation.MachineMoreDefectsTest do
  @moduledoc """
  Regression tests that reproduce further conversation machine defects found in the
  code review (see vault note "20 - Codebase Review Findings"). Every test is
  expected to FAIL on the current code and pass once the matching finding is fixed.

  Run only these:  mix test --only known_bug
  Skip these:      mix test --exclude known_bug
  """
  use SuperPi.DataCase, async: false

  import Ecto.Query

  alias SuperPi.Conversation.Machine
  alias SuperPi.Durable.{Context, Doc, Storage}
  alias SuperPi.Durable.Schemas.Task, as: TaskSchema
  alias SuperPi.TestSupport.Faults

  @moduletag :known_bug

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  defp submit(pid, text, opts \\ []) do
    Machine.submit(pid, text, Keyword.put_new(opts, :timeout, 3_000))
  catch
    :exit, reason -> {:exit, reason}
  end

  defp generation_tasks(conv_id) do
    Repo.all(from t in TaskSchema, where: t.conversation_id == ^conv_id and t.kind == "pi.generation")
  end

  # Waits until `pid` has at least one message queued (the blocked machine cannot consume it).
  defp wait_for_queued_message(pid, tries \\ 200) do
    {:message_queue_len, len} = Process.info(pid, :message_queue_len)

    cond do
      len >= 1 ->
        :ok

      tries == 0 ->
        flunk("steer call never reached the machine mailbox")

      true ->
        Process.sleep(5)
        wait_for_queued_message(pid, tries - 1)
    end
  end

  defp wait_for_state(pid, state, tries \\ 300) do
    case Machine.get_state(pid) do
      {^state, _} ->
        :ok

      _ when tries == 0 ->
        flunk("machine never reached #{inspect(state)}")

      _ ->
        Process.sleep(5)
        wait_for_state(pid, state, tries - 1)
    end
  end

  defp message_texts(conv_id) do
    {entries, _} = Context.visible_entries_with_graph(conv_id)

    for %{kind: "pi.message", data: %{"role" => "user", "content" => [%{"text" => t} | _]}} <- entries, do: t
  end

  describe "steer preemption (machine.ex:180-190)" do
    test "steer sent during a turn stays in the same run: one pi.generation task, steer text once" do
      conv = Storage.create_conversation!()
      test_pid = self()
      counter = :counters.new(1, [])

      responder = fn _payload, _ctx ->
        :counters.add(counter, 1, 1)

        if :counters.get(counter, 1) == 1 do
          send(test_pid, {:responder_started, self()})

          receive do
            :release -> {:ok, Faults.text_msg("first")}
          after
            15_000 -> {:error, :timeout}
          end
        else
          {:ok, Faults.text_msg("after steer")}
        end
      end

      {:ok, pid} = Machine.start_link(conversation_id: conv.id, llm_responder: responder)

      first = Task.async(fn -> submit(pid, "start", timeout: 10_000) end)
      assert_receive {:responder_started, responder_pid}, 5_000

      steer = Task.async(fn -> submit(pid, "STEER-ME", mode: :steer, timeout: 10_000) end)
      wait_for_queued_message(pid)

      send(responder_pid, :release)
      Task.await(first, 10_000)
      Task.await(steer, 10_000)

      assert length(generation_tasks(conv.id)) == 1,
             "steer was replayed at :idle as a new submit, creating a second pi.generation task"

      assert Enum.count(message_texts(conv.id), &(&1 == "STEER-ME")) == 1
    end

    test "steer during a tool batch skips remaining tools and leaves no assistant tool_call without a result" do
      conv = Storage.create_conversation!()
      test_pid = self()

      responder = fn payload, _ctx ->
        if Enum.any?(payload.messages, &(&1["role"] == "tool")) do
          {:ok, Faults.text_msg("done")}
        else
          {:ok,
           %{
             "role" => "assistant",
             "content" => [
               %{"type" => "tool_call", "id" => "call_a", "name" => "t", "arguments" => %{"n" => "a"}},
               %{"type" => "tool_call", "id" => "call_b", "name" => "t", "arguments" => %{"n" => "b"}}
             ]
           }}
        end
      end

      executor = fn _name, %{"n" => n}, _ctx ->
        send(test_pid, {:executed, n, self()})

        if n == "a" do
          receive do
            :release -> :ok
          after
            15_000 -> :ok
          end
        end

        %{"output" => "ok-#{n}", "details" => %{}}
      end

      {:ok, pid} = Machine.start_link(conversation_id: conv.id, llm_responder: responder, tool_executor: executor)

      first = Task.async(fn -> submit(pid, "go", timeout: 10_000) end)
      assert_receive {:executed, "a", tool_pid}, 5_000

      steer = Task.async(fn -> submit(pid, "STEER-ME", mode: :steer, timeout: 10_000) end)
      wait_for_queued_message(pid)

      send(tool_pid, :release)
      Task.await(first, 10_000)
      Task.await(steer, 10_000)

      refute_received {:executed, "b", _}, "remaining tool in the batch ran despite the steer"

      messages = Context.derive(conv.id).messages

      call_ids =
        for %{"role" => "assistant", "content" => c} when is_list(c) <- messages,
            %{"type" => "tool_call", "id" => id} <- c,
            do: id

      result_ids = for %{"role" => "tool", "tool_call_id" => id} <- messages, do: id

      assert call_ids -- result_ids == [],
             "assistant tool_calls without tool results: #{inspect(call_ids -- result_ids)}"
    end
  end

  describe "backoff (machine.ex:298-306)" do
    test "Machine.compact/2 while :sleeping_backoff does not crash the machine" do
      conv = Storage.create_conversation!()
      counter = :counters.new(1, [])

      responder = fn _p, _c ->
        :counters.add(counter, 1, 1)

        if :counters.get(counter, 1) == 1,
          do: {:retry_after, 1_500},
          else: {:ok, Faults.text_msg("ok")}
      end

      {:ok, pid} = Machine.start_link(conversation_id: conv.id, llm_responder: responder)

      first = Task.async(fn -> submit(pid, "hi", timeout: 8_000) end)
      wait_for_state(pid, :sleeping_backoff)

      result =
        try do
          Machine.compact(pid)
        catch
          :exit, reason -> {:exit, reason}
        end

      alive? = Process.alive?(pid)
      if alive?, do: Process.exit(pid, :kill)
      Task.shutdown(first, :brutal_kill)

      assert alive?, "machine crashed on compact in :sleeping_backoff: #{inspect(result)}"
      refute match?({:exit, _}, result), "got: #{inspect(result)}"
    end

    test "{:retry_after, ms} is capped: an always-rate-limited responder ends the run with an error" do
      conv = Storage.create_conversation!()

      {:ok, pid} =
        Machine.start_link(conversation_id: conv.id, llm_responder: fn _p, _c -> {:retry_after, 5} end)

      result = submit(pid, "hi", timeout: 2_500)
      if Process.alive?(pid), do: Process.exit(pid, :kill)

      assert {:error, _} = result, "run never ended, got: #{inspect(result)}"
    end
  end

  describe "hook context (machine.ex:645)" do
    defmodule CaptureCtx do
      use SuperPi.Extension

      @impl true
      def before_agent_start(cfg, ctx) do
        send(Keyword.fetch!(ctx.config, :test_pid), {:ctx, ctx})
        {:ok, cfg}
      end
    end

    test "extensions see ctx.workspace_root from the agent doc workspacePaths" do
      dir = Path.join(System.tmp_dir!(), "ws_root_#{System.unique_integer([:positive])}")
      conv = Storage.create_conversation!()
      Storage.configure_agent!(conv.id, %{"workspacePaths" => [dir]})

      {:ok, pid} =
        Machine.start_link(
          conversation_id: conv.id,
          extensions: [{CaptureCtx, [test_pid: self()]}],
          llm_responder: fn _p, _c -> {:ok, Faults.text_msg("hi")} end
        )

      assert {:ok, _} = submit(pid, "hello")
      assert_receive {:ctx, ctx}, 1_000

      assert Map.get(ctx, :workspace_root) == dir,
             "workspace_root missing; plugins fall back to File.cwd!(). ctx keys: #{inspect(Map.keys(ctx))}"
    end
  end

  describe "tool control directives (machine.ex:598-607)" do
    test "a control map with both add_tools and handoff applies both" do
      conv = Storage.create_conversation!()
      new_tool = %{"name" => "extra_tool", "description" => "added at runtime"}

      executor = fn _n, _a, _c ->
        %{
          "output" => "ok",
          "details" => %{},
          "control" => %{"add_tools" => [new_tool], "handoff" => %{"model" => "handoff-model"}}
        }
      end

      {:ok, pid} =
        Machine.start_link(
          conversation_id: conv.id,
          llm_responder: Faults.tool_then_text_responder("any_tool", %{}, "done"),
          tool_executor: executor
        )

      assert {:ok, _} = submit(pid, "go")

      agent = Doc.snapshot("conversation", conv.id, "pi.agent") || %{}
      tool_names = for t <- Map.get(agent, "tools", []), do: t["name"]

      assert "extra_tool" in tool_names, "add_tools not applied: #{inspect(agent)}"
      assert agent["model"] == "handoff-model", "handoff not applied: #{inspect(agent)}"
    end
  end

  describe "on_input media (machine.ex:147)" do
    defmodule MediaInput do
      use SuperPi.Extension

      @impl true
      def on_input(_input, _ctx), do: {:transform, "see image", [%{"type" => "image", "data" => "IMG-BYTES-123"}]}
    end

    test "media returned by on_input is kept in the user message" do
      conv = Storage.create_conversation!()

      {:ok, pid} =
        Machine.start_link(
          conversation_id: conv.id,
          extensions: [MediaInput],
          llm_responder: fn _p, _c -> {:ok, Faults.text_msg("hi")} end
        )

      assert {:ok, _} = submit(pid, "raw")

      {entries, _} = Context.visible_entries_with_graph(conv.id)
      user = Enum.find(entries, &(&1.kind == "pi.message" and &1.data["role"] == "user"))

      assert inspect(user.data) =~ "IMG-BYTES-123", "media dropped: #{inspect(user.data)}"
    end
  end
end
