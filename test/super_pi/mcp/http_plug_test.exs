defmodule SuperPi.MCP.HTTPPlugTest do
  @moduledoc "The Streamable HTTP server, end to end through the gateway router (`Plug.Test`)."
  use SuperPi.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias SuperPi.Drain
  alias SuperPi.Gateway.Router
  alias SuperPi.Harness
  alias SuperPi.MCP.{HTTPPlug, Sessions}

  @router Router.init([])

  setup do
    SuperPi.Tools.ensure_catalog_ets!()
    Sessions.clear()

    keys = [
      :gateway_tokens,
      :gateway_token,
      :permissions,
      :mcp_allowed_origins,
      :mcp_session_ttl_ms,
      :mcp_max_sessions
    ]

    saved = for key <- keys, do: {key, Application.fetch_env(:super_pi, key)}
    Application.put_env(:super_pi, :permissions, allowNonWorkspaceAccess: true)
    Enum.each([:gateway_tokens, :gateway_token], &Application.delete_env(:super_pi, &1))

    on_exit(fn ->
      Drain.resume()
      Sessions.clear()

      for {key, saved} <- saved do
        case saved do
          {:ok, v} -> Application.put_env(:super_pi, key, v)
          :error -> Application.delete_env(:super_pi, key)
        end
      end
    end)

    :ok
  end

  defp rpc(id, method, params \\ %{}),
    do: %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

  defp post(body, headers \\ [], path \\ "/mcp") do
    conn = conn(:post, path, if(is_binary(body), do: body, else: Jason.encode!(body)))

    headers =
      [{"content-type", "application/json"}, {"accept", "application/json, text/event-stream"}] ++
        headers

    conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    Router.call(conn, @router)
  end

  defp request(method, headers) do
    conn = Enum.reduce(headers, conn(method, "/mcp"), fn {k, v}, c -> put_req_header(c, k, v) end)
    Router.call(conn, @router)
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)

  defp initialize(headers \\ [], path \\ "/mcp", version \\ "2025-06-18") do
    conn =
      post(
        rpc(1, "initialize", %{"protocolVersion" => version, "clientInfo" => %{"name" => "test"}}),
        headers,
        path
      )

    [session] = get_resp_header(conn, "mcp-session-id")
    {conn, session}
  end

  defp with_session(session, extra \\ []), do: [{"mcp-session-id", session}] ++ extra

  describe "initialize" do
    test "answers the negotiated version and issues a session id" do
      {conn, session} = initialize()

      assert conn.status == 200
      assert ["application/json" <> _] = get_resp_header(conn, "content-type")

      assert %{
               "id" => 1,
               "result" => %{
                 "protocolVersion" => "2025-06-18",
                 "serverInfo" => %{"name" => "super-pi-beam"}
               }
             } = json(conn)

      assert byte_size(session) >= 20
      assert Sessions.count() == 1
    end

    test "negotiates down for an older client and for an unknown one" do
      {conn, _} = initialize([], "/mcp", "2024-11-05")
      assert json(conn)["result"]["protocolVersion"] == "2024-11-05"

      {conn, _} = initialize([], "/mcp", "2026-07-28")
      assert json(conn)["result"]["protocolVersion"] == "2025-06-18"
    end

    test "every initialize starts its own session" do
      {_, a} = initialize()
      {_, b} = initialize()
      assert a != b
      assert Sessions.count() == 2
    end

    test "initialize cannot be batched" do
      conn = post([rpc(1, "initialize", %{}), rpc(2, "ping")])
      assert conn.status == 400
      assert get_resp_header(conn, "mcp-session-id") == []
      assert Sessions.count() == 0
    end

    test "?harness= selects the harness of the session, an unknown one is 400" do
      [_, second | _] = Harness.list()
      {_, session} = initialize([], "/mcp?harness=#{second.id()}")
      assert {:ok, %{harness: harness}} = Sessions.fetch(session)
      assert harness == second.id()

      conn = post(rpc(1, "initialize", %{}), [], "/mcp?harness=nope")
      assert conn.status == 400
      assert json(conn)["error"]["message"] =~ "Unknown harness"
    end
  end

  describe "requests" do
    test "tools/list and tools/call run through the engine" do
      {_, session} = initialize()

      conn = post(rpc(2, "tools/list"), with_session(session))
      assert conn.status == 200
      assert %{"result" => %{"tools" => tools}} = json(conn)
      assert length(tools) == 8
      assert Enum.all?(tools, &is_map(&1["annotations"]))

      conn =
        post(
          rpc(3, "tools/call", %{"name" => "ls", "arguments" => %{"path" => System.tmp_dir!()}}),
          with_session(session)
        )

      assert %{"id" => 3, "result" => %{"isError" => false, "structuredContent" => _}} =
               json(conn)
    end

    test "state carries across requests of one session: the tool session is reused" do
      {_, session} = initialize()

      call =
        rpc(2, "tools/call", %{"name" => "ls", "arguments" => %{"path" => System.tmp_dir!()}})

      post(call, with_session(session))
      {:ok, %{tool_session: first}} = Sessions.fetch(session)
      post(call, with_session(session))
      {:ok, %{tool_session: second}} = Sessions.fetch(session)

      assert first.conversation_id == second.conversation_id
    end

    test "a notification is 202 with no body" do
      {_, session} = initialize()

      conn =
        post(
          %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
          with_session(session)
        )

      assert conn.status == 202
      assert conn.resp_body == ""
    end

    test "a response from the client is 202 and does not reach the engine" do
      {_, session} = initialize()
      conn = post(%{"jsonrpc" => "2.0", "id" => 99, "result" => %{}}, with_session(session))
      assert conn.status == 202
    end

    test "a batch is answered with an array, in order, without the notification" do
      {_, session} = initialize()

      conn =
        post(
          [
            rpc(2, "ping"),
            %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
            rpc(3, "tools/list")
          ],
          with_session(session)
        )

      assert [%{"id" => 2}, %{"id" => 3}] = json(conn)

      conn =
        post(
          [%{"jsonrpc" => "2.0", "method" => "notifications/initialized"}],
          with_session(session)
        )

      assert conn.status == 202
    end

    test "an unknown method is a JSON-RPC error with status 200" do
      {_, session} = initialize()
      conn = post(rpc(2, "nope/nope"), with_session(session))
      assert conn.status == 200
      assert json(conn)["error"]["code"] == -32601
    end

    test "an invalid JSON-RPC object is 400" do
      {_, session} = initialize()
      conn = post(%{"hello" => "world"}, with_session(session))
      assert conn.status == 400
      assert json(conn)["error"]["code"] == -32600
    end

    test "a body that is not JSON is 400" do
      {_, session} = initialize()
      conn = post("{not json", with_session(session))
      assert conn.status == 400
    end

    test "the reply is an event when the client accepts only text/event-stream" do
      {_, session} = initialize()
      conn = post(rpc(2, "ping"), [{"accept", "text/event-stream"}] ++ with_session(session))

      assert conn.status == 200
      assert ["text/event-stream" <> _] = get_resp_header(conn, "content-type")
      assert "event: message\ndata: " <> rest = conn.resp_body
      assert %{"id" => 2, "result" => %{}} = rest |> String.trim() |> Jason.decode!()
    end
  end

  describe "sessions" do
    test "a request without a session id is 400, with an unknown one is 404" do
      assert post(rpc(2, "tools/list")).status == 400

      conn = post(rpc(2, "tools/list"), with_session("made-up"))
      assert conn.status == 404
      assert json(conn)["error"]["message"] =~ "initialize again"
    end

    test "DELETE ends the session; a second DELETE and a later request are 404" do
      {_, session} = initialize()

      assert request(:delete, with_session(session)).status == 200
      assert Sessions.count() == 0
      assert request(:delete, with_session(session)).status == 404
      assert post(rpc(2, "ping"), with_session(session)).status == 404
    end

    test "DELETE without a session id is 400" do
      assert request(:delete, []).status == 400
    end

    test "an expired session is 404" do
      Application.put_env(:super_pi, :mcp_session_ttl_ms, 20)
      {_, session} = initialize()
      Process.sleep(60)
      assert post(rpc(2, "ping"), with_session(session)).status == 404
    end

    test "use keeps a session alive" do
      Application.put_env(:super_pi, :mcp_session_ttl_ms, 150)
      {_, session} = initialize()

      for _ <- 1..4 do
        Process.sleep(60)
        assert post(rpc(2, "ping"), with_session(session)).status == 200
      end
    end

    test "the number of sessions is capped" do
      Application.put_env(:super_pi, :mcp_max_sessions, 2)
      initialize()
      initialize()

      conn = post(rpc(1, "initialize", %{}))
      assert conn.status == 503
      assert get_resp_header(conn, "mcp-session-id") == []
    end
  end

  describe "GET and other methods" do
    test "GET is 405 and names the allowed methods" do
      conn = request(:get, [{"accept", "text/event-stream"}])
      assert conn.status == 405
      assert get_resp_header(conn, "allow") == ["POST, DELETE"]
    end

    test "PUT is 405" do
      assert request(:put, []).status == 405
    end

    test "a path below /mcp is 404" do
      conn =
        Router.call(
          conn(:post, "/mcp/other", "{}") |> put_req_header("content-type", "application/json"),
          @router
        )

      assert conn.status == 404
    end
  end

  describe "checks" do
    test "an unsupported MCP-Protocol-Version is 400, a supported one passes" do
      {_, session} = initialize()

      assert post(rpc(2, "ping"), with_session(session, [{"mcp-protocol-version", "2026-07-28"}])).status ==
               400

      assert post(rpc(2, "ping"), with_session(session, [{"mcp-protocol-version", "2025-03-26"}])).status ==
               200
    end

    test "a draining node is 503 with Retry-After" do
      {_, session} = initialize()
      Drain.stop_accepting()

      conn = post(rpc(2, "ping"), with_session(session))
      assert conn.status == 503
      assert json(conn)["error"]["message"] =~ "shutting down"

      # Ending a session is still allowed.
      assert request(:delete, with_session(session)).status == 200
    end

    test "with no token configured, a foreign Origin is 403 and a loopback one passes" do
      assert post(rpc(1, "initialize", %{}), [{"origin", "https://evil.example.com"}]).status ==
               403

      assert post(rpc(1, "initialize", %{}), [{"origin", "http://localhost:5173"}]).status == 200
      assert post(rpc(1, "initialize", %{}), [{"origin", "http://127.0.0.1:3000"}]).status == 200
    end

    test "an Origin in mcp_allowed_origins passes" do
      Application.put_env(:super_pi, :mcp_allowed_origins, ["https://app.example.com"])

      assert post(rpc(1, "initialize", %{}), [{"origin", "https://app.example.com"}]).status ==
               200

      assert post(rpc(1, "initialize", %{}), [{"origin", "https://other.example.com"}]).status ==
               403
    end
  end

  describe "authentication (inherited from the gateway)" do
    setup do
      Application.put_env(:super_pi, :gateway_tokens, [{"alice", "tok-alice"}, {"bob", "tok-bob"}])

      :ok
    end

    defp bearer(token), do: [{"authorization", "Bearer " <> token}]

    test "without a token every method is 401" do
      assert post(rpc(1, "initialize", %{})).status == 401
      assert request(:delete, [{"mcp-session-id", "x"}]).status == 401
      assert request(:get, []).status == 401
    end

    test "a wrong token is 401, a right one opens a session" do
      assert post(rpc(1, "initialize", %{}), bearer("nope")).status == 401
      {conn, session} = initialize(bearer("tok-alice"))
      assert conn.status == 200
      assert {:ok, %{principal: "alice"}} = Sessions.fetch(session)
    end

    test "a session belongs to the principal that opened it" do
      {_, session} = initialize(bearer("tok-alice"))

      assert post(rpc(2, "ping"), with_session(session, bearer("tok-alice"))).status == 200
      assert post(rpc(2, "ping"), with_session(session, bearer("tok-bob"))).status == 404
      assert request(:delete, with_session(session, bearer("tok-bob"))).status == 404
      assert request(:delete, with_session(session, bearer("tok-alice"))).status == 200
    end

    test "a transcript resource is private to the principal that ran the task" do
      {_, session} = initialize(bearer("tok-alice"))

      call =
        rpc(2, "tools/call", %{
          "name" => "harness_task",
          "arguments" => %{"prompt" => "alice's plan"}
        })

      conv_id =
        post(call, with_session(session, bearer("tok-alice")))
        |> json()
        |> get_in(["result", "structuredContent", "conversation_id"])

      uri = "superpi://conversation/#{conv_id}/transcript"

      read = rpc(3, "resources/read", %{"uri" => uri})

      assert [%{"text" => text}] =
               post(read, with_session(session, bearer("tok-alice")))
               |> json()
               |> get_in(["result", "contents"])

      assert text =~ "alice's plan"

      {_, bob} = initialize(bearer("tok-bob"))

      assert post(read, with_session(bob, bearer("tok-bob")))
             |> json()
             |> get_in(["error", "code"]) == -32002
    end

    test "origin checks do not apply when tokens are configured" do
      assert post(
               rpc(1, "initialize", %{}),
               bearer("tok-alice") ++ [{"origin", "https://evil.example.com"}]
             ).status == 200
    end
  end

  describe "the MCP client against this server, over a socket" do
    setup do
      {:ok, server} =
        Bandit.start_link(
          plug: Router,
          scheme: :http,
          ip: {127, 0, 0, 1},
          port: 0,
          startup_log: false
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
      on_exit(fn -> Process.alive?(server) && Process.exit(server, :normal) end)
      %{url: "http://127.0.0.1:#{port}/mcp"}
    end

    test "handshake, tool listing, a call, and a new session after the server forgot the old one",
         %{url: url} do
      {:ok, client} = SuperPi.MCP.Client.start_link(name: "self", url: url)
      assert :ok = SuperPi.MCP.Client.await_ready(client, 5_000)

      tools = SuperPi.MCP.Client.tools(client)
      assert length(tools) == 8
      assert Enum.find(tools, &(&1["name"] == "read"))["annotations"]["readOnlyHint"] == true

      args = %{"path" => System.tmp_dir!()}

      assert {:ok, %{"isError" => false, "structuredContent" => %{}}} =
               SuperPi.MCP.Client.call_tool(client, "ls", args)

      # The server restarted, as far as the client can tell.
      Sessions.clear()
      assert {:ok, %{"isError" => false}} = SuperPi.MCP.Client.call_tool(client, "ls", args)
      assert Sessions.count() == 1

      GenServer.stop(client)
      Process.sleep(100)
      assert Sessions.count() == 0
    end

    test "a bearer token in the client's headers", %{url: url} do
      Application.put_env(:super_pi, :gateway_tokens, [{"alice", "tok-alice"}])
      System.put_env("SUPER_PI_TEST_MCP_TOKEN", "tok-alice")
      on_exit(fn -> System.delete_env("SUPER_PI_TEST_MCP_TOKEN") end)

      {:ok, denied} = SuperPi.MCP.Client.start_link(name: "denied", url: url)

      assert {:error, {:handshake_failed, %{"message" => "HTTP 401" <> _}}} =
               SuperPi.MCP.Client.await_ready(denied, 5_000)

      {:ok, client} =
        SuperPi.MCP.Client.start_link(
          name: "ok",
          url: url,
          headers: %{"Authorization" => "Bearer ${SUPER_PI_TEST_MCP_TOKEN}"}
        )

      assert :ok = SuperPi.MCP.Client.await_ready(client, 5_000)
    end
  end

  describe "the plug on its own" do
    test "reads the body itself when no parser ran" do
      conn =
        conn(:post, "/", Jason.encode!(rpc(1, "initialize", %{})))
        |> put_req_header("content-type", "application/json")
        |> HTTPPlug.call(HTTPPlug.init([]))

      assert conn.status == 200
      assert [_] = get_resp_header(conn, "mcp-session-id")
    end
  end
end
