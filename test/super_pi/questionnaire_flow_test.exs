defmodule SuperPi.QuestionnaireFlowTest do
  @moduledoc "ask_question end to end: broker, plugin and the RPC `ui.respond` method."
  use SuperPi.DataCase, async: false

  alias SuperPi.Plugins.Questionnaire
  alias SuperPi.RPC.Server, as: RPC
  alias SuperPi.UI.Broker

  @questions [%{"question" => "Which backend?", "options" => ["(Recommended) SQLite", "PostgreSQL"]}]

  setup do
    on_exit(fn -> Application.delete_env(:super_pi, :questionnaire_timeout_ms) end)
    %{conv: SuperPi.Durable.Storage.create_conversation!()}
  end

  defp ask(conv_id), do: Questionnaire.wrap_tool("ask_question", %{"questions" => @questions}, fn _ -> %{} end, %{conversation_id: conv_id})

  # Runs `ask` in a process that watches the conversation like a client does.
  defp start_asking(conv_id) do
    me = self()
    Phoenix.PubSub.subscribe(SuperPi.PubSub, "conversation:#{conv_id}")
    Broker.register_responder(conv_id)
    task =
      Task.async(fn ->
        send(me, :asking)
        ask(conv_id)
      end)
    assert_receive {:conversation_event, ^conv_id, %{"type" => "ui_request"} = event}, 5_000
    {task, event}
  end

  test "a client answers and the tool returns the user's choice", %{conv: conv} do
    {task, event} = start_asking(conv.id)

    assert event["kind"] == "questionnaire"
    assert [%{"question" => "Which backend?"}] = event["questions"]
    assert :ok = Broker.respond(event["request_id"], [%{"question" => "Which backend?", "selected" => "PostgreSQL"}])

    res = Task.await(task, 5_000)
    refute res["is_error"]
    assert res["structured_output"]["source"] == "user"
    assert res["output"] =~ "Answer: PostgreSQL"
  end

  test "a bare string answers a single question", %{conv: conv} do
    {task, event} = start_asking(conv.id)
    Broker.respond(event["request_id"], "PostgreSQL")
    assert Task.await(task, 5_000)["output"] =~ "PostgreSQL"
  end

  test "multi-select answers are joined", %{conv: conv} do
    {task, event} = start_asking(conv.id)
    Broker.respond(event["request_id"], ["SQLite", "PostgreSQL"])
    assert Task.await(task, 5_000)["output"] =~ "SQLite, PostgreSQL"
  end

  test "an unusable answer is an error, not a guess", %{conv: conv} do
    {task, event} = start_asking(conv.id)
    Broker.respond(event["request_id"], 42)
    res = Task.await(task, 5_000)
    assert res["is_error"]
    assert res["structured_output"]["status"] == "invalid_answer"
  end

  test "cancelling the conversation ends the wait", %{conv: conv} do
    {task, _event} = start_asking(conv.id)
    Broker.cancel_pending(conv.id)
    assert Task.await(task, 5_000)["structured_output"]["status"] == "cancelled"
  end

  test "an unanswered question times out", %{conv: conv} do
    Application.put_env(:super_pi, :questionnaire_timeout_ms, 100)
    {task, _event} = start_asking(conv.id)
    assert Task.await(task, 5_000)["structured_output"]["status"] == "timeout"
  end

  test "a responder that has exited does not count", %{conv: conv} do
    pid = spawn(fn -> Broker.register_responder(conv.id) end)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, _, _, _}
    refute Broker.responder?(conv.id)
    assert ask(conv.id)["structured_output"]["status"] == "no_interactive_client"
  end

  test "an answer to an unknown request is refused" do
    assert {:error, :unknown_request} = Broker.respond("ui-nope", "x")
  end

  test "empty or malformed questions are rejected before anything is asked", %{conv: conv} do
    for args <- [%{"questions" => []}, %{"questions" => [%{"options" => ["a"]}]}, %{}] do
      res = Questionnaire.wrap_tool("ask_question", args, fn _ -> %{} end, %{conversation_id: conv.id})
      assert res["structured_output"]["status"] == "invalid_arguments"
    end
  end

  describe "rpc" do
    defp rpc(state, method, params, id \\ 1) do
      RPC.handle_rpc_payload(Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}), state)
    end

    test "watch with interactive registers the client, ui.respond delivers the answer", %{conv: conv} do
      refute Broker.responder?(conv.id)
      {%{"result" => _}, state, _} = rpc(RPC.new_client_state(), "session.watch", %{"conversation_id" => conv.id, "interactive" => true})
      assert Broker.responder?(conv.id)

      task = Task.async(fn -> ask(conv.id) end)
      assert_receive {:conversation_event, _, %{"type" => "ui_request", "request_id" => request_id}}, 5_000

      {reply, _, _} = rpc(state, "ui.respond", %{"request_id" => request_id, "value" => "PostgreSQL"})
      assert %{"result" => %{"resolved" => ^request_id}} = reply
      assert Task.await(task, 5_000)["output"] =~ "PostgreSQL"
    end

    test "watch without interactive does not register", %{conv: conv} do
      rpc(RPC.new_client_state(), "session.watch", %{"conversation_id" => conv.id})
      refute Broker.responder?(conv.id)
    end

    test "ui.respond with an unknown id is an error" do
      {reply, _, _} = rpc(RPC.new_client_state(), "ui.respond", %{"request_id" => "ui-nope", "value" => "x"})
      assert %{"error" => %{"code" => -32004}} = reply
    end

    test "session.cancel ends a waiting question", %{conv: conv} do
      rpc(RPC.new_client_state(), "session.watch", %{"conversation_id" => conv.id, "interactive" => true})
      task = Task.async(fn -> ask(conv.id) end)
      assert_receive {:conversation_event, _, %{"type" => "ui_request"}}, 5_000

      rpc(RPC.new_client_state(), "session.cancel", %{"conversation_id" => conv.id})
      assert Task.await(task, 5_000)["structured_output"]["status"] == "cancelled"
    end

    test "another principal cannot answer a question on someone else's conversation" do
      Application.put_env(:super_pi, :gateway_tokens, alice: "tok-a", bob: "tok-b")
      on_exit(fn -> Application.delete_env(:super_pi, :gateway_tokens) end)

      {_, alice, _} = rpc(RPC.new_client_state(), "auth.login", %{"token" => "tok-a"})
      {_, bob, _} = rpc(RPC.new_client_state(), "auth.login", %{"token" => "tok-b"})
      {%{"result" => %{"conversation_id" => conv_id}}, _, _} = rpc(alice, "session.open", %{})

      rpc(alice, "session.watch", %{"conversation_id" => conv_id, "interactive" => true})
      task = Task.async(fn -> ask(conv_id) end)
      assert_receive {:conversation_event, _, %{"type" => "ui_request", "request_id" => request_id}}, 5_000

      {reply, _, _} = rpc(bob, "ui.respond", %{"request_id" => request_id, "value" => "PostgreSQL"})
      assert %{"error" => %{"code" => -32004}} = reply

      {reply, _, _} = rpc(alice, "ui.respond", %{"request_id" => request_id, "value" => "SQLite"})
      assert %{"result" => _} = reply
      assert Task.await(task, 5_000)["output"] =~ "SQLite"
    end
  end
end
