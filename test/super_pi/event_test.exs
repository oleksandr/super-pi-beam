defmodule SuperPi.EventTest do
  use SuperPi.DataCase, async: false
  use ExUnitProperties

  alias SuperPi.Conversation.Machine
  alias SuperPi.Durable.Storage
  alias SuperPi.Event
  alias SuperPi.Event.Renderer
  alias SuperPi.TestSupport.Faults

  describe "wire form" do
    test "keeps the payload at the top level and adds v and turn_id" do
      wire = 7 |> Event.text_delta(3, 0, "hi") |> Event.to_wire()
      assert %{"type" => "text_delta", "conversation_id" => 7, "turn_id" => 3, "index" => 0, "delta" => "hi", "v" => 1} = wire
      assert is_integer(wire["timestamp_ms"])
      refute Map.has_key?(wire, "data")
    end

    test "round-trips through from_wire/1, and reads a map from an older producer" do
      ev = Event.tool_completed(1, 2, "c1", "bash", false, "out")
      assert ev |> Event.to_wire() |> Event.from_wire() == ev
      assert %Event{type: "text_delta", v: 1, turn_id: nil, data: %{"delta" => "x"}} = Event.from_wire(%{"type" => "text_delta", "delta" => "x"})
    end

    test "every builder yields a type in the vocabulary" do
      events = [
        Event.turn_started(1, 1, 0),
        Event.turn_completed(1, 1, %{}, 0),
        Event.turn_error(1, 1, :boom, 0),
        Event.turn_cancelled(1, 1, 0),
        Event.text_delta(1, 1, 0, "a"),
        Event.thinking_delta(1, 1, 0, "a"),
        Event.toolcall_delta(1, 1, 0, "{", %{}),
        Event.message_completed(1, 1, "assistant", [], %{}),
        Event.tool_started(1, 1, "c", "n", %{}),
        Event.tool_blocked(1, 1, "c", "n", "r"),
        Event.tool_completed(1, 1, "c", "n", false, ""),
        Event.permission_request(1, 1, %{"request_id" => "r", "options" => Event.permission_options()}),
        Event.ui_request(1, "r", %{"kind" => "questionnaire"}),
        Event.ui_resolved(1, "r", "answered"),
        Event.state_changed(1, 1, "idle"),
        Event.mode_changed(1, "plan", "plan"),
        Event.stream_reset(1, 1, 100),
        Event.compaction_completed(1, 5, "s"),
        Event.usage_updated(1, 1, %{"input_tokens" => 1}),
        Event.plan_updated(1, []),
        Event.notice(1, 1, "info", "m"),
        Event.watch_started(1, 0),
        Event.subagent_started(1, 1, 2, "scout", "find it"),
        Event.subagent_finished(1, 1, 2, "completed", "found")
      ]

      assert Enum.map(events, & &1.type) |> Enum.sort() == Enum.sort(Event.types())
    end

    test "an extension event keeps its payload, and cannot forge the envelope" do
      ev = Event.from_extension(5, 9, %{"type" => "custom", "conversation_id" => 99, "turn_id" => 99, "x" => 1})
      assert %Event{type: "custom", conversation_id: 5, turn_id: 9, data: %{"x" => 1}} = ev
    end

    test "a tool call delta carries the provider's id and name only when it has them" do
      assert %{"id" => "c1", "name" => "read"} = 1 |> Event.toolcall_delta(1, 0, "{", %{}, id: "c1", name: "read") |> Event.to_wire()
      wire = 1 |> Event.toolcall_delta(1, 0, "{", %{}) |> Event.to_wire()
      refute Map.has_key?(wire, "id")
      refute Map.has_key?(wire, "name")
    end

    test "turn_error formats a non-binary reason" do
      assert %{"error" => ":boom"} = 1 |> Event.turn_error(1, :boom, 0) |> Event.to_wire()
    end
  end

  describe "the machine publishes the turn" do
    setup do
      conv = Storage.create_conversation!()
      Phoenix.PubSub.subscribe(SuperPi.PubSub, "conversation:#{conv.id}")
      {:ok, conv: conv}
    end

    defp types_until(conv_id, terminal, acc \\ []) do
      receive do
        {:conversation_event, ^conv_id, %{"type" => type} = ev} ->
          acc = acc ++ [ev]
          if type in terminal, do: acc, else: types_until(conv_id, terminal, acc)
      after
        2_000 -> flunk("no terminal event, got #{inspect(Enum.map(acc, & &1["type"]))}")
      end
    end

    test "turn_started, message_completed, usage_updated and turn_completed, all with the turn id", %{conv: conv} do
      {:ok, pid} = Machine.start_link(conversation_id: conv.id, llm_responder: fn _p, _c -> {:ok, Faults.text_msg("hello")} end)
      {:ok, _} = Machine.submit(pid, "hi", timeout: 3_000)

      events = types_until(conv.id, ["turn_completed"])
      types = Enum.map(events, & &1["type"])

      assert hd(Enum.filter(types, &(&1 in ["turn_started", "message_completed", "turn_completed"]))) == "turn_started"
      assert "message_completed" in types
      assert List.last(types) == "turn_completed"

      turn_id = Enum.find(events, &(&1["type"] == "turn_started"))["turn_id"]
      assert is_integer(turn_id)
      assert Enum.find(events, &(&1["type"] == "turn_completed")) |> Map.take(["turn_id", "stop_reason", "v"]) == %{"turn_id" => turn_id, "stop_reason" => "end_turn", "v" => 1}
      assert Enum.find(events, &(&1["type"] == "message_completed"))["role"] == "assistant"
    end

    test "a failing responder ends in turn_error", %{conv: conv} do
      {:ok, pid} = Machine.start_link(conversation_id: conv.id, llm_responder: fn _p, _c -> {:error, "provider down"} end)
      assert {:error, _} = Machine.submit(pid, "hi", timeout: 3_000)
      assert %{"error" => error} = types_until(conv.id, ["turn_error"]) |> List.last()
      assert error =~ "provider down"
    end

    test "a cancelled turn ends in turn_cancelled, once", %{conv: conv} do
      {:ok, pid} = Machine.start_link(conversation_id: conv.id, llm_responder: Faults.blocking_responder(self(), "x"))
      task = Task.async(fn -> Machine.submit(pid, "hi", timeout: 3_000) end)
      assert_receive {:responder_started, responder}
      on_exit(fn -> if Process.alive?(responder), do: send(responder, :release) end)
      Machine.cancel(pid)
      Task.await(task)

      assert %{"type" => "turn_cancelled"} = types_until(conv.id, ["turn_cancelled"]) |> List.last()
      refute_receive {:conversation_event, _, %{"type" => "turn_cancelled"}}, 200
      refute_receive {:conversation_event, _, %{"type" => "turn_completed"}}, 10
      refute_receive {:conversation_event, _, %{"type" => "turn_error"}}, 10
    end

    test "a tool call publishes started and completed with the same tool call id", %{conv: conv} do
      {:ok, pid} =
        Machine.start_link(
          conversation_id: conv.id,
          llm_responder: Faults.tool_then_text_responder("read", %{"path" => "x"}, "done"),
          tool_executor: fn _n, _a, _c -> %{"output" => "ok"} end
        )

      {:ok, _} = Machine.submit(pid, "go", timeout: 3_000)
      events = types_until(conv.id, ["turn_completed"])
      started = Enum.find(events, &(&1["type"] == "tool_started"))
      completed = Enum.find(events, &(&1["type"] == "tool_completed"))
      assert started["tool_call_id"] == completed["tool_call_id"]
      assert started["turn_id"] == completed["turn_id"]
    end

    test "a settings change publishes mode_changed, and a todo publishes plan_updated", %{conv: conv} do
      Storage.configure_agent!(conv.id, %{"executionMode" => "plan", "maxExecutionMode" => "plan"})
      assert_receive {:conversation_event, _, %{"type" => "mode_changed", "mode" => "plan", "max_mode" => "plan"}}

      SuperPi.Plugins.Todo.wrap_tool("todo", %{"action" => "add", "text" => "a"}, fn _ -> %{} end, %{conversation_id: conv.id})
      assert_receive {:conversation_event, _, %{"type" => "plan_updated", "entries" => [%{"text" => "a", "completed" => false}]}}
    end
  end

  describe "OpenAI renderer (the Gateway's SSE output)" do
    @state [id: "chatcmpl-1", created: 100, model: "m"]

    defp ev(map), do: Event.from_wire(map)

    test "text and thinking deltas are the chunks that the Gateway always sent" do
      chunks =
        Renderer.render_all(Renderer.OpenAI, [ev(%{"type" => "text_delta", "delta" => "A"}), ev(%{"type" => "thinking_delta", "delta" => "B"})], @state)

      assert Enum.map(chunks, &Jason.encode!/1) == [
               ~s({"choices":[{"delta":{"content":"A"},"finish_reason":null,"index":0}],"created":100,"id":"chatcmpl-1","model":"m","object":"chat.completion.chunk"}),
               ~s({"choices":[{"delta":{"reasoning_content":"B"},"finish_reason":null,"index":0}],"created":100,"id":"chatcmpl-1","model":"m","object":"chat.completion.chunk"})
             ]
    end

    test "tool progress goes to reasoning_content with the argument preview" do
      [started, done] =
        Renderer.render_all(
          Renderer.OpenAI,
          [
            ev(%{"type" => "tool_started", "name" => "bash", "arguments" => %{"command" => "ls"}}),
            ev(%{"type" => "tool_completed", "name" => "bash", "is_error" => false, "output" => "a\nb"})
          ],
          @state
        )

      assert get_in(started, ["choices", Access.at(0), "delta", "reasoning_content"]) == "⚙️ Executing bash: $ ls\n"
      assert get_in(done, ["choices", Access.at(0), "delta", "reasoning_content"]) == "✅ bash completed -> a\nb\n\n"
    end

    test "long output is cut at 80 characters and other events render nothing" do
      long = String.duplicate("x", 200)
      [done] = Renderer.render_all(Renderer.OpenAI, [ev(%{"type" => "tool_completed", "name" => "t", "is_error" => true, "output" => long})], @state)
      text = get_in(done, ["choices", Access.at(0), "delta", "reasoning_content"])
      assert text == "❌ t completed -> " <> String.duplicate("x", 81) <> "...\n\n"

      assert [] = Renderer.render_all(Renderer.OpenAI, [ev(%{"type" => "state_changed", "status" => "idle"}), ev(%{"type" => "turn_completed"})], @state)
    end

    test "role, finish and usage chunks" do
      st = Renderer.OpenAI.init(@state)
      assert %{"choices" => [%{"delta" => %{"role" => "assistant"}, "finish_reason" => nil, "index" => 0}]} = Renderer.OpenAI.role_chunk(st)
      assert %{"choices" => [%{"delta" => %{}, "finish_reason" => "stop"}]} = Renderer.OpenAI.finish_chunk(st, "stop")
      assert %{"choices" => [], "usage" => %{"total_tokens" => 3}} = Renderer.OpenAI.usage_chunk(st, %{"total_tokens" => 3})
    end

    property "a text delta round-trips any UTF-8 string through the chunk" do
      check all text <- string(:printable) do
        [chunk] = Renderer.render_all(Renderer.OpenAI, [Event.text_delta(1, nil, 0, text)], @state)
        assert chunk |> Jason.encode!() |> Jason.decode!() |> get_in(["choices", Access.at(0), "delta", "content"]) == text
      end
    end
  end

  describe "RPC and TUI renderers" do
    test "RPC is the identity on the wire map" do
      event = Event.tool_started(1, 2, "c", "n", %{"a" => 1})
      assert [Event.to_wire(event)] == Renderer.render_all(Renderer.RPC, [event])
    end

    test "TUI tags its output" do
      out =
        Renderer.render_all(Renderer.TUI, [
          Event.text_delta(1, 1, 0, "hi"),
          Event.tool_started(1, 1, "c", "bash", %{}),
          Event.ui_request(1, "r", %{"kind" => "questionnaire", "questions" => []}),
          Event.permission_request(1, 1, %{"request_id" => "p"}),
          Event.turn_completed(1, 1, %{}, 0),
          Event.turn_cancelled(1, 1, 0),
          Event.turn_error(1, 1, "bad", 0),
          Event.state_changed(1, 1, "idle")
        ])

      assert [{:text, "hi"}, {:line, "[tool] bash"}, {:ask, %{"request_id" => "r"}}, {:permission, %{"request_id" => "p"}}, {:done, :ok}, {:done, :cancelled}, {:done, {:error, "bad"}}] = out
    end
  end
end
