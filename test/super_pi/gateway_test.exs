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
    assert "super-pi-planner" in model_ids
    assert "super-pi-fast" in model_ids
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

  test "GET /unknown returns 404 error" do
    conn =
      conn(:get, "/unknown-endpoint")
      |> Router.call(@opts)

    assert conn.status == 404
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] == "not_found"
  end
end
