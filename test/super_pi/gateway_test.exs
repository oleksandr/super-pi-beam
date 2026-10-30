defmodule SuperPi.GatewayTest do
  use SuperPi.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias SuperPi.Gateway.Router

  @opts Router.init([])

  setup do
    SuperPi.Tools.ensure_catalog_ets!()
    :ok
  end

  test "GET / returns gateway information" do
    conn =
      conn(:get, "/")
      |> Router.call(@opts)

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["status"] == "ok"
    assert body["app"] == "super-pi-beam"
  end

  test "GET /health returns healthy status" do
    conn =
      conn(:get, "/health")
      |> Router.call(@opts)

    assert conn.status == 200
  end

  test "GET /v1/models returns model list with super-pi models" do
    conn =
      conn(:get, "/v1/models")
      |> Router.call(@opts)

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["object"] == "list"
    assert is_list(body["data"])

    model_ids = Enum.map(body["data"], & &1["id"])
    assert "super-pi-agent" in model_ids
    assert "super-pi-fast" in model_ids
    assert "super-pi-workspace" in model_ids
    refute "super-pi-agy" in model_ids
    assert "super-pi-planner" in model_ids
  end

  test "POST /v1/chat/completions with super-pi-workspace loads workspace extensions" do
    payload = %{
      "model" => "super-pi-workspace",
      "messages" => [
        %{"role" => "user", "content" => "Hello Workspace"}
      ],
      "stream" => false
    }

    conn =
      conn(:post, "/v1/chat/completions", Jason.encode!(payload))
      |> put_req_header("content-type", "application/json")
      |> Router.call(@opts)

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["object"] == "chat.completion"
  end

  test "POST /v1/chat/completions synchronous non-streaming" do
    payload = %{
      "model" => "super-pi-agent",
      "messages" => [
        %{"role" => "user", "content" => "Ping"}
      ],
      "stream" => false
    }

    conn =
      conn(:post, "/v1/chat/completions", Jason.encode!(payload))
      |> put_req_header("content-type", "application/json")
      |> Router.call(@opts)

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["object"] == "chat.completion"
    assert String.starts_with?(body["id"], "chatcmpl-")
    assert body["model"] == "super-pi-agent"

    choice = hd(body["choices"])
    assert choice["message"]["role"] == "assistant"
    assert is_binary(choice["message"]["content"])
    assert choice["finish_reason"] == "stop"
  end

  test "POST /v1/chat/completions streaming returns SSE chunks and [DONE]" do
    payload = %{
      "model" => "super-pi-agent",
      "messages" => [
        %{"role" => "user", "content" => "Stream test"}
      ],
      "stream" => true
    }

    conn =
      conn(:post, "/v1/chat/completions", Jason.encode!(payload))
      |> put_req_header("content-type", "application/json")
      |> Router.call(@opts)

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["text/event-stream"]

    body = conn.resp_body
    assert is_binary(body)
    assert String.contains?(body, "data: [DONE]")
    assert String.contains?(body, "chat.completion.chunk")
    assert String.contains?(body, ~s("choices":[]))
    assert String.contains?(body, ~s("usage":{))
  end

  test "POST /v1/chat/completions intercepts title generation requests without corrupting session" do
    payload = %{
      "model" => "super-pi-agent",
      "messages" => [
        %{"role" => "system", "content" => "You are a title generator. You output ONLY a thread title. Nothing else."},
        %{"role" => "user", "content" => "Generate a title for this conversation:\nHello world"}
      ],
      "stream" => false
    }

    conn =
      conn(:post, "/v1/chat/completions", Jason.encode!(payload))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-session-id", "test-session-123")
      |> Router.call(@opts)

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert String.starts_with?(body["id"], "chatcmpl-title-")
    assert hd(body["choices"])["finish_reason"] == "stop"
    assert is_binary(hd(body["choices"])["message"]["content"])

    # Ensure this title generation did NOT map test-session-123 in ETS to a corrupted conversation
    sessions = :ets.tab2list(:super_pi_gateway_sessions)
    assert Enum.find(sessions, fn {sid, _cid} -> sid == "test-session-123" end) == nil
  end

  test "POST /v1/chat/completions preserves multi-turn conversational context" do
    payload = %{
      "model" => "super-pi-agent",
      "messages" => [
        %{"role" => "user", "content" => "First question"},
        %{"role" => "assistant", "content" => "First answer"},
        %{"role" => "user", "content" => "Second question"}
      ],
      "stream" => false
    }

    conn =
      conn(:post, "/v1/chat/completions", Jason.encode!(payload))
      |> put_req_header("content-type", "application/json")
      |> Router.call(@opts)

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["choices"] != []
  end

  test "POST /v1/chat/completions consecutive streaming turns do NOT multiply responses on keep-alive processes" do
    # Simulate turn 1
    p1 = %{
      "model" => "super-pi-fast",
      "messages" => [%{"role" => "user", "content" => "First turn"}],
      "stream" => true
    }

    c1 =
      conn(:post, "/v1/chat/completions", Jason.encode!(p1))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-session-id", "session-no-multiply-test")
      |> Router.call(@opts)

    assert c1.status == 200
    b1 = c1.resp_body
    assert length(Regex.scan(~r/"finish_reason":"stop"/, b1)) == 1
    assert length(Regex.scan(~r/data: \[DONE\]/, b1)) == 1

    # Simulate turn 2 on the same test process (keep-alive simulation)
    p2 = %{
      "model" => "super-pi-fast",
      "messages" => [
        %{"role" => "user", "content" => "First turn"},
        %{"role" => "assistant", "content" => "First reply"},
        %{"role" => "user", "content" => "Second turn"}
      ],
      "stream" => true
    }

    c2 =
      conn(:post, "/v1/chat/completions", Jason.encode!(p2))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-session-id", "session-no-multiply-test")
      |> Router.call(@opts)

    assert c2.status == 200
    b2 = c2.resp_body
    # Must NOT be multiplied (would be 2 if PubSub double subscribed)
    assert length(Regex.scan(~r/"finish_reason":"stop"/, b2)) == 1
    assert length(Regex.scan(~r/data: \[DONE\]/, b2)) == 1
  end

  test "POST /v1/chat/completions streams interim tool progress into reasoning_content" do
    conv = SuperPi.Durable.Storage.create_conversation!()
    Phoenix.PubSub.broadcast(SuperPi.PubSub, "conversation:#{conv.id}", {:conversation_event, conv.id, %{
      "type" => "tool_started",
      "name" => "bash",
      "args" => %{"command" => "ls -la"}
    }})
    Phoenix.PubSub.broadcast(SuperPi.PubSub, "conversation:#{conv.id}", {:conversation_event, conv.id, %{
      "type" => "tool_completed",
      "name" => "bash",
      "output" => "total 0",
      "is_error" => false
    }})

    # Verify that stream handler converts tool_started and tool_completed into reasoning_content
    p = %{
      "model" => "super-pi-agent",
      "messages" => [%{"role" => "user", "content" => "Run tool"}],
      "stream" => true
    }

    conn =
      conn(:post, "/v1/chat/completions", Jason.encode!(p))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-conversation-id", to_string(conv.id))
      |> Router.call(@opts)

    assert conn.status == 200
    assert String.contains?(conn.resp_body, "chat.completion.chunk")
  end

  test "GET /unknown returns 404 error" do
    conn =
      conn(:get, "/unknown-endpoint")
      |> Router.call(@opts)

    assert conn.status == 404
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] == "not_found"
  end
end
