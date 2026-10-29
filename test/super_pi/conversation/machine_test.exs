defmodule SuperPi.Conversation.MachineTest do
  use SuperPi.DataCase, async: false
  use ExUnitProperties

  alias SuperPi.Conversation.Machine
  alias SuperPi.Durable.{Context, Storage}

  defmodule TestAuditExtension do
    use SuperPi.Extension

    @impl true
    def on_input("/ping", _ctx), do: :handled
    def on_input(text, _ctx), do: {:transform, String.trim(text), []}

    @impl true
    def before_tool("forbidden_tool", _args, _ctx), do: {:block, "policy_violation"}
    def before_tool(_name, args, _ctx), do: {:mutate_input, Map.put(args, "audited", true)}

    @impl true
    def after_tool(_name, _args, result, _ctx) do
      {:ok, Map.update(result, "details", %{"hooked" => true}, &Map.put(&1, "hooked", true))}
    end
  end

  defmodule OneShotVerificationExtension do
    use SuperPi.Extension

    @impl true
    def after_run(summary, _ctx) do
      last_text =
        summary.last_message
        |> Map.get("content", [])
        |> Enum.find_value("", fn b -> if b["type"] == "text", do: b["text"] end)

      if String.contains?(last_text, "NEEDS_VERIFY") do
        {:continue, "Please fix the verification warning and finalize."}
      else
        :accept
      end
    end
  end

  describe "Property-Based & Integration Tests: Conversation :gen_statem & 12-Hook Pipeline" do
    property "arbitrary sequences of :queue and :write submissions execute in order and preserve context invariants" do
      check all(
              ops <-
                list_of(
                  tuple({
                    member_of([:queue, :write]),
                    string(:alphanumeric, min_length: 3, max_length: 20)
                  }),
                  min_length: 2,
                  max_length: 8
                ),
              max_runs: 25
            ) do
        conv = Storage.create_conversation!()
        {:ok, pid} = Machine.start_link(conversation_id: conv.id, extensions: [TestAuditExtension])

        Enum.each(ops, fn {mode, text} ->
          res = Machine.submit(pid, text, mode: mode)
          assert match?({:ok, _}, res)
        end)

        {state_name, _data} = Machine.get_state(pid)
        assert state_name == :idle

        derived = Context.derive(conv.id)
        queue_count = Enum.count(ops, fn {m, _} -> m == :queue end)
        write_count = Enum.count(ops, fn {m, _} -> m == :write end)

        # Every :queue produces 1 user message + 1 assistant reply; every :write produces 1 user message
        assert length(derived.messages) == queue_count * 2 + write_count

        GenServer.stop(pid)
      end
    end

    test "executes multi-tool batches with before_tool permission gating, after_tool enrichment, and dynamic add_tools control" do
      conv = Storage.create_conversation!()

      # Responder calls two tools on turn 1 (`allowed_tool` and `forbidden_tool`), then replies with text on turn 2
      responder = fn payload, _ctx ->
        has_tool_results? = Enum.any?(payload.messages, &(&1["role"] == "tool"))

        if not has_tool_results? do
          {:ok,
           %{
             "role" => "assistant",
             "content" => [
               %{
                 "type" => "tool_call",
                 "id" => "call_1",
                 "name" => "allowed_tool",
                 "arguments" => %{"target" => "alpha"}
               },
               %{
                 "type" => "tool_call",
                 "id" => "call_2",
                 "name" => "forbidden_tool",
                 "arguments" => %{"target" => "secret"}
               }
             ]
           }}
        else
          {:ok,
           %{
             "role" => "assistant",
             "content" => [%{"type" => "text", "text" => "Completed tool inspection."}]
           }}
        end
      end

      executor = fn "allowed_tool", args, _ctx ->
        assert args["audited"] == true

        %{
          "output" => "ok:#{args["target"]}",
          "structured_output" => %{"status" => "ok"},
          "details" => %{"ran" => true},
          "control" => %{"add_tools" => [%{"name" => "newly_activated_tool", "description" => "dynamic"}]}
        }
      end

      {:ok, pid} =
        Machine.start_link(
          conversation_id: conv.id,
          extensions: [TestAuditExtension],
          llm_responder: responder,
          tool_executor: executor
        )

      # Test `on_input` `:handled` short-circuit
      assert {:ok, :handled_by_extension} = Machine.submit(pid, "/ping")

      # Submit full tool-calling turn
      assert {:ok, final_msg} = Machine.submit(pid, "run tools")
      assert [%{"text" => "Completed tool inspection."}] = final_msg["content"]

      derived = Context.derive(conv.id)
      tool_msgs = Enum.filter(derived.messages, &(&1["role"] == "tool"))
      assert length(tool_msgs) == 2

      [t1, t2] = tool_msgs
      assert t1["is_error"] == false
      assert t1["content"] == "ok:alpha"
      assert t1["details"]["hooked"] == true

      assert t2["is_error"] == true
      assert String.contains?(t2["content"], "Blocked by extension: policy_violation")

      # Verify dynamic `add_tools` control updated active tools in context
      assert Enum.any?(derived.tools, &(&1["name"] == "newly_activated_tool"))

      GenServer.stop(pid)
    end

    test "after_run verification hook automatically continues generation until verification passes" do
      conv = Storage.create_conversation!()

      responder = fn payload, _ctx ->
        user_msgs = Enum.filter(payload.messages, &(&1["role"] == "user"))

        if length(user_msgs) == 1 do
          {:ok,
           %{
             "role" => "assistant",
             "content" => [%{"type" => "text", "text" => "Draft response NEEDS_VERIFY"}]
           }}
        else
          {:ok,
           %{
             "role" => "assistant",
             "content" => [%{"type" => "text", "text" => "Verified final response!"}]
           }}
        end
      end

      {:ok, pid} =
        Machine.start_link(
          conversation_id: conv.id,
          extensions: [OneShotVerificationExtension],
          llm_responder: responder
        )

      {:ok, final_msg} = Machine.submit(pid, "build feature")
      assert [%{"text" => "Verified final response!"}] = final_msg["content"]

      derived = Context.derive(conv.id)
      assert length(derived.messages) == 4

      GenServer.stop(pid)
    end
  end
end
