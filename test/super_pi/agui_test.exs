defmodule SuperPi.AGUITest do
  use SuperPi.DataCase, async: false
  use ExUnitProperties
  import Plug.Conn
  import Plug.Test

  alias SuperPi.Conversation.Machine
  alias SuperPi.Durable.Storage
  alias SuperPi.Event
  alias SuperPi.Event.Renderer
  alias SuperPi.Event.Renderer.AGUI
  alias SuperPi.Gateway.{Router, Sessions}
  alias SuperPi.TestSupport.Faults

  @opts Router.init([])

  defp render(events, opts \\ []),
    do: Renderer.render_all(AGUI, events, Keyword.merge([thread_id: "t1", run_id: "r1"], opts))

  defp types(items), do: Enum.map(items, & &1["type"])

  describe "renderer" do
    test "a run of bare deltas gets one message start and end around it" do
      items =
        render([
          Event.turn_started(1, 5, 0),
          Event.text_delta(1, 5, 0, "he"),
          Event.text_delta(1, 5, 0, "llo"),
          Event.message_completed(1, 5, "assistant", [], %{}),
          Event.turn_completed(1, 5, %{}, 1)
        ])

      assert types(items) == [
               "RUN_STARTED",
               "TEXT_MESSAGE_START",
               "TEXT_MESSAGE_CONTENT",
               "TEXT_MESSAGE_CONTENT",
               "TEXT_MESSAGE_END",
               "RUN_FINISHED"
             ]

      assert [%{"threadId" => "t1", "runId" => "r1"}] =
               Enum.filter(items, &(&1["type"] == "RUN_STARTED"))

      [start | _] = Enum.filter(items, &(&1["type"] == "TEXT_MESSAGE_START"))

      assert Enum.all?(
               Enum.filter(items, &(&1["type"] in ["TEXT_MESSAGE_CONTENT", "TEXT_MESSAGE_END"])),
               &(&1["messageId"] == start["messageId"])
             )
    end

    test "reasoning closes before the answer text starts, and a run end closes whatever is open" do
      items =
        render([
          Event.thinking_delta(1, 5, 0, "hm"),
          Event.text_delta(1, 5, 0, "a"),
          Event.turn_completed(1, 5, %{}, 1)
        ])

      assert types(items) == [
               "REASONING_START",
               "REASONING_MESSAGE_START",
               "REASONING_MESSAGE_CONTENT",
               "REASONING_MESSAGE_END",
               "REASONING_END",
               "TEXT_MESSAGE_START",
               "TEXT_MESSAGE_CONTENT",
               "TEXT_MESSAGE_END",
               "RUN_FINISHED"
             ]
    end

    test "tool_started is TOOL_CALL_END, and tool_completed is the result" do
      items =
        render([
          Event.toolcall_delta(1, 5, 0, ~s({"path":), %{})
          |> put_in([Access.key(:data), "id"], "c1")
          |> put_in([Access.key(:data), "name"], "read"),
          Event.toolcall_delta(1, 5, 0, ~s("x"}), %{"path" => "x"})
          |> put_in([Access.key(:data), "id"], "c1")
          |> put_in([Access.key(:data), "name"], "read"),
          Event.tool_started(1, 5, "c1", "read", %{"path" => "x"}),
          Event.tool_completed(1, 5, "c1", "read", false, "contents")
        ])

      assert types(items) == [
               "TOOL_CALL_START",
               "TOOL_CALL_ARGS",
               "TOOL_CALL_ARGS",
               "TOOL_CALL_END",
               "TOOL_CALL_RESULT"
             ]

      assert [%{"toolCallId" => "c1", "toolCallName" => "read"}] =
               Enum.filter(items, &(&1["type"] == "TOOL_CALL_START"))

      assert %{"content" => "contents", "toolCallId" => "c1", "role" => "tool"} = List.last(items)
    end

    test "a tool call that was not streamed gets start, args and end together" do
      items =
        render([
          Event.tool_started(1, 5, "c9", "bash", %{"command" => "ls"}),
          Event.tool_completed(1, 5, "c9", "bash", false, "x")
        ])

      assert types(items) == [
               "TOOL_CALL_START",
               "TOOL_CALL_ARGS",
               "TOOL_CALL_END",
               "TOOL_CALL_RESULT"
             ]

      assert Enum.find(items, &(&1["type"] == "TOOL_CALL_ARGS"))["delta"] == ~s({"command":"ls"})
    end

    test "a streamed call without an id in the delta is matched to tool_started by order" do
      items =
        render([
          Event.toolcall_delta(1, 5, 0, "{}", %{}),
          Event.tool_started(1, 5, "real-id", "read", %{}),
          Event.tool_completed(1, 5, "real-id", "read", false, "ok")
        ])

      ids =
        items
        |> Enum.filter(&Map.has_key?(&1, "toolCallId"))
        |> Enum.map(& &1["toolCallId"])
        |> Enum.uniq()

      assert length(ids) == 1, "one logical call, got ids #{inspect(ids)}"
    end

    test "errors and cancellation end the run with RUN_ERROR" do
      assert ["RUN_ERROR"] = types(render([Event.turn_error(1, 5, "boom", 0)]))
      [cancelled] = render([Event.turn_cancelled(1, 5, 0)])
      assert %{"type" => "RUN_ERROR", "code" => "cancelled"} = cancelled
    end

    test "state events become STATE_DELTA relative to the snapshot, never when nothing changed" do
      st =
        AGUI.init(
          projection: %{
            "status" => "idle",
            "mode" => "accept-edits",
            "plan" => [],
            "pendingPermission" => nil
          }
        )

      {[snapshot], st} = AGUI.snapshot(st)
      assert %{"type" => "STATE_SNAPSHOT", "snapshot" => %{"status" => "idle"}} = snapshot

      {[delta], st} = AGUI.render(Event.state_changed(1, 1, "executing_tools"), st)

      assert %{
               "type" => "STATE_DELTA",
               "delta" => [%{op: "replace", path: "/status", value: "executing_tools"}]
             } = delta

      {[], st} = AGUI.render(Event.state_changed(1, 1, "executing_tools"), st)
      {[delta], _} = AGUI.render(Event.mode_changed(1, "plan", "plan"), st)
      assert Enum.any?(delta["delta"], &(&1.path == "/mode" and &1.value == "plan"))
    end

    test "a permission request shows as a CUSTOM event and as pending state, and ui_resolved clears it" do
      st = AGUI.init(projection: %{"status" => "idle", "pendingPermission" => nil})

      req =
        Event.permission_request(1, 5, %{
          "request_id" => "r1",
          "tool_call_id" => "c1",
          "tool_name" => "x",
          "reason" => "why",
          "risk" => "high",
          "options" => []
        })

      {items, st} = AGUI.render(req, st)
      assert ["CUSTOM", "STATE_DELTA"] = types(items)

      assert %{
               "name" => "permission_request",
               "value" => %{"requestId" => "r1", "toolName" => "x"}
             } = hd(items)

      {items, _} = AGUI.render(Event.ui_resolved(1, "r1", "answered"), st)
      assert ["CUSTOM", "STATE_DELTA"] = types(items)

      assert [%{op: "replace", path: "/pendingPermission", value: nil}] =
               List.last(items)["delta"]
    end

    test "compaction gives a MESSAGES_SNAPSHOT from the messages function" do
      items =
        render([Event.compaction_completed(1, 3, "s")],
          messages_fun: fn -> [%{"id" => "m", "role" => "user", "content" => "hi"}] end
        )

      assert [%{"type" => "MESSAGES_SNAPSHOT", "messages" => [%{"id" => "m"}]}] = items
    end

    property "coalescing keeps the text of any delta sequence and merges neighbours" do
      check all(
              deltas <- list_of(string(:printable, min_length: 1), min_length: 1, max_length: 20)
            ) do
        raw = render(Enum.map(deltas, &Event.text_delta(1, 5, 0, &1)))
        merged = AGUI.coalesce(raw)

        joined = fn items ->
          items
          |> Enum.filter(&(&1["type"] == "TEXT_MESSAGE_CONTENT"))
          |> Enum.map_join(& &1["delta"])
        end

        assert joined.(merged) == Enum.join(deltas)
        assert length(Enum.filter(merged, &(&1["type"] == "TEXT_MESSAGE_CONTENT"))) == 1
      end
    end

    property "every item is JSON encodable and has a type and a timestamp" do
      check all(deltas <- list_of(string(:printable), max_length: 10)) do
        items =
          render(
            [Event.turn_started(1, 5, 0) | Enum.map(deltas, &Event.text_delta(1, 5, 0, &1))] ++
              [Event.turn_completed(1, 5, %{}, 1)]
          )

        for item <- items,
            do:
              assert(
                is_binary(item["type"]) and is_integer(item["timestamp"]) and
                  is_binary(Jason.encode!(item))
              )
      end
    end
  end

  describe "HTTP" do
    defp sse_events(body) do
      body
      |> String.split("\n\n", trim: true)
      |> Enum.filter(&String.starts_with?(&1, "data: "))
      |> Enum.map(fn "data: " <> json -> Jason.decode!(json) end)
    end

    defp post(path, body, headers \\ []) do
      Enum.reduce(
        headers,
        conn(:post, path, Jason.encode!(body))
        |> put_req_header("content-type", "application/json"),
        fn {k, v}, c -> put_req_header(c, k, v) end
      )
      |> Router.call(@opts)
    end

    defp start_thread(thread, responder, tool_executor \\ nil) do
      conv = Storage.create_conversation!(agent: SuperPi.Harness.Assistant.agent_defaults())

      {conv_id, true} =
        Sessions.fetch_or_create(SuperPi.Auth.anonymous(), "agui:" <> thread, fn -> conv end)

      assert conv_id == conv.id

      opts =
        [conversation_id: conv.id, llm_responder: responder] ++
          if(tool_executor, do: [tool_executor: tool_executor], else: [])

      {:ok, pid} = Machine.start_link(opts)
      {conv, pid}
    end

    test "POST /run streams RUN_STARTED, a snapshot, the message and RUN_FINISHED" do
      start_thread("t-run", fn _p, ctx ->
        ctx.emit_event.(%{"type" => "text_delta", "index" => 0, "delta" => "Hel"})
        ctx.emit_event.(%{"type" => "text_delta", "index" => 0, "delta" => "lo"})
        {:ok, Faults.text_msg("Hello")}
      end)

      conn =
        post("/agui/v1/run", %{
          "threadId" => "t-run",
          "runId" => "run-1",
          "messages" => [%{"id" => "m1", "role" => "user", "content" => "hi"}]
        })

      assert conn.status == 200
      assert ["text/event-stream" <> _] = get_resp_header(conn, "content-type")

      items = sse_events(conn.resp_body)
      kinds = Enum.map(items, & &1["type"])

      assert hd(kinds) == "STATE_SNAPSHOT"
      assert "RUN_STARTED" in kinds
      assert List.last(kinds) == "RUN_FINISHED"

      assert %{"threadId" => "t-run", "runId" => "run-1"} =
               Enum.find(items, &(&1["type"] == "RUN_STARTED"))

      text =
        items
        |> Enum.filter(&(&1["type"] == "TEXT_MESSAGE_CONTENT"))
        |> Enum.map_join(& &1["delta"])

      assert text == "Hello"
      assert Enum.count(kinds, &(&1 == "TEXT_MESSAGE_START")) == 1
      assert Enum.count(kinds, &(&1 == "TEXT_MESSAGE_END")) == 1
    end

    test "a failing run ends in RUN_ERROR" do
      start_thread("t-err", fn _p, _c -> {:error, "provider down"} end)

      conn =
        post("/agui/v1/run", %{
          "threadId" => "t-err",
          "messages" => [%{"role" => "user", "content" => "hi"}]
        })

      items = sse_events(conn.resp_body)
      assert %{"type" => "RUN_ERROR", "message" => msg} = List.last(items)
      assert msg =~ "provider down"
    end

    test "a bad request is a 400 with no stream" do
      assert %{status: 400} = post("/agui/v1/run", %{"messages" => []})
      assert %{status: 400} = post("/agui/v1/run", %{"threadId" => "x", "messages" => []})

      assert %{status: 400} =
               post("/agui/v1/run", %{
                 "threadId" => "x",
                 "messages" => [%{"role" => "user", "content" => "hi"}],
                 "forwardedProps" => %{"harness" => "nope"}
               })
    end

    test "input: unknown conversations and foreign request ids are refused" do
      assert %{status: 404} = post("/agui/v1/sessions/999999/input", %{"type" => "cancel"})
      {conv, _pid} = start_thread("t-in", fn _p, _c -> {:ok, Faults.text_msg("x")} end)

      assert %{status: 404} =
               post("/agui/v1/sessions/#{conv.id}/input", %{
                 "type" => "permission",
                 "request_id" => "ui-0-nope",
                 "option_id" => "allow_once"
               })

      assert %{status: 400} = post("/agui/v1/sessions/#{conv.id}/input", %{"type" => "weird"})
      assert %{status: 200} = post("/agui/v1/sessions/#{conv.id}/input", %{"type" => "cancel"})
    end

    test "a permission request in a run is answered through the input route" do
      conv_tool = %{"name" => "mcp__x__y", "effects" => ["net_write"]}

      {conv, pid} =
        start_thread(
          "t-perm",
          Faults.tool_then_text_responder("mcp__x__y", %{}, "done"),
          fn _n, _a, _c -> %{"output" => "ran"} end
        )

      Storage.configure_agent!(conv.id, %{
        "tools" => [conv_tool],
        "workspace" => %{"kind" => "local"},
        "executionMode" => "accept-edits"
      })

      Machine.set_extensions(pid, [SuperPi.Plugins.Permissions])

      # Subscribe first: the request is published as soon as the run starts.
      Phoenix.PubSub.subscribe(SuperPi.PubSub, Event.topic(conv.id))

      run =
        Task.async(fn ->
          # The route installs the extensions of the named harness. Code carries Permissions.
          post("/agui/v1/run", %{
            "threadId" => "t-perm",
            "messages" => [%{"role" => "user", "content" => "go"}],
            "forwardedProps" => %{"harness" => "super-pi-code"}
          })
        end)

      assert_receive {:conversation_event, _,
                      %{"type" => "permission_request", "request_id" => request_id}},
                     5_000

      assert %{status: 200} =
               post("/agui/v1/sessions/#{conv.id}/input", %{
                 "type" => "permission",
                 "request_id" => request_id,
                 "option_id" => "allow_once"
               })

      conn = Task.await(run, 10_000)
      items = sse_events(conn.resp_body)
      assert Enum.any?(items, &(&1["type"] == "CUSTOM" and &1["name"] == "permission_request"))
      assert Enum.any?(items, &(&1["type"] == "TOOL_CALL_RESULT" and &1["content"] == "ran"))
      assert List.last(items)["type"] == "RUN_FINISHED"
    end
  end

  describe "History" do
    test "builds AG-UI messages with tool calls and results from the stored entries" do
      conv = Storage.create_conversation!()

      Storage.append_entry!(conv.id, "pi.message", %{
        "role" => "user",
        "content" => [%{"type" => "text", "text" => "hi"}]
      })

      Storage.append_entry!(conv.id, "pi.message", %{
        "role" => "assistant",
        "content" => [
          %{"type" => "text", "text" => "calling"},
          %{
            "type" => "tool_call",
            "id" => "c1",
            "name" => "read",
            "arguments" => %{"path" => "x"}
          }
        ]
      })

      Storage.append_entry!(conv.id, "pi.message", %{
        "role" => "tool",
        "tool_call_id" => "c1",
        "name" => "read",
        "content" => "data"
      })

      assert [
               %{"role" => "user", "content" => "hi"},
               %{
                 "role" => "assistant",
                 "content" => "calling",
                 "toolCalls" => [%{"id" => "c1", "function" => %{"name" => "read"}}]
               },
               %{"role" => "tool", "content" => "data", "toolCallId" => "c1"}
             ] = Event.History.agui_messages(conv.id)
    end
  end
end
