defmodule SuperPi.AuthTest do
  @moduledoc "Authentication and conversation ownership for Gateway, RPC and MCP (doc 24 P1)."
  use SuperPi.DataCase, async: false
  import Plug.Test
  import Plug.Conn

  alias SuperPi.Auth
  alias SuperPi.Gateway.Router
  alias SuperPi.RPC.Server, as: RPC

  @opts Router.init([])

  setup do
    saved =
      Enum.map(
        [:gateway_tokens, :gateway_token, :permissions],
        &{&1, Application.fetch_env(:super_pi, &1)}
      )

    System.delete_env("SUPER_PI_GATEWAY_TOKEN")

    on_exit(fn ->
      Enum.each(saved, fn
        {k, {:ok, v}} -> Application.put_env(:super_pi, k, v)
        {k, :error} -> Application.delete_env(:super_pi, k)
      end)

      System.delete_env("SUPER_PI_GATEWAY_TOKEN")
    end)

    Enum.each([:gateway_tokens, :gateway_token], &Application.delete_env(:super_pi, &1))
    :ok
  end

  defp tokens(list), do: Application.put_env(:super_pi, :gateway_tokens, list)

  describe "Auth.authenticate/1" do
    test "is open with no tokens configured" do
      refute Auth.required?()
      assert {:ok, "anonymous"} = Auth.authenticate(nil)
      assert {:ok, "anonymous"} = Auth.authenticate("anything")
    end

    test "accepts a configured token and names the principal" do
      tokens(alice: "tok-a", bob: "tok-b")
      assert Auth.required?()
      assert {:ok, "alice"} = Auth.authenticate("tok-a")
      assert {:ok, "bob"} = Auth.authenticate("tok-b")
    end

    test "rejects a wrong, empty or missing token" do
      tokens(alice: "tok-a")
      assert :error = Auth.authenticate("tok-x")
      assert :error = Auth.authenticate("")
      assert :error = Auth.authenticate(nil)
    end

    test "an unnamed token gets a stable hashed principal that does not contain the token" do
      tokens(["secret-token"])
      assert {:ok, principal} = Auth.authenticate("secret-token")
      assert String.starts_with?(principal, "token:")
      refute principal =~ "secret"
      assert {:ok, ^principal} = Auth.authenticate("secret-token")
    end

    test "reads the legacy :gateway_token key and the environment" do
      Application.put_env(:super_pi, :gateway_token, "legacy")
      System.put_env("SUPER_PI_GATEWAY_TOKEN", "env-one, env-two")

      assert {:ok, _} = Auth.authenticate("legacy")
      assert {:ok, _} = Auth.authenticate("env-one")
      assert {:ok, _} = Auth.authenticate("env-two")
      assert :error = Auth.authenticate("other")
    end

    test "bearer_token/1" do
      assert Auth.bearer_token("Bearer abc") == "abc"
      assert Auth.bearer_token("Basic abc") == nil
      assert Auth.bearer_token("") == nil
    end
  end

  describe "gateway" do
    defp request(method, path, token \\ nil, body \\ nil, headers \\ []) do
      conn =
        conn(method, path, body && Jason.encode!(body))
        |> put_req_header("content-type", "application/json")

      conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
      conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
      Router.call(conn, @opts)
    end

    defp chat(token, headers) do
      body = %{
        "model" => "gemini-3-flash-preview",
        "messages" => [%{"role" => "user", "content" => "hi"}]
      }

      request(:post, "/v1/chat/completions", token, body, headers)
    end

    test "with no tokens the gateway is open" do
      assert request(:get, "/v1/models").status == 200
    end

    test "with tokens a request without a valid key gets 401 in the OpenAI error shape" do
      tokens(alice: "tok-a")

      for token <- [nil, "wrong"] do
        conn = request(:get, "/v1/models", token)
        assert conn.status == 401
        assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
        assert %{"error" => %{"code" => "invalid_api_key"}} = Jason.decode!(conn.resp_body)
      end
    end

    test "a valid key is accepted" do
      tokens(alice: "tok-a")
      assert request(:get, "/v1/models", "tok-a").status == 200
    end

    test "/health stays open" do
      tokens(alice: "tok-a")
      assert request(:get, "/health").status == 200
    end

    test "a bad key never reaches the agent" do
      tokens(alice: "tok-a")
      before = SuperPi.Gateway.Sessions.count()
      assert chat("wrong", [{"x-session-id", "s-denied"}]).status == 401
      assert SuperPi.Gateway.Sessions.count() == before
    end

    test "principals do not share a session id" do
      tokens(alice: "tok-a", bob: "tok-b")
      assert chat("tok-a", [{"x-session-id", "shared"}]).status == 200
      assert chat("tok-b", [{"x-session-id", "shared"}]).status == 200

      assert a = SuperPi.Gateway.Sessions.lookup("alice", "shared")
      assert b = SuperPi.Gateway.Sessions.lookup("bob", "shared")
      assert a != b
      assert Auth.owner(a) == "alice"
      assert Auth.owner(b) == "bob"
    end

    test "a principal cannot attach to another principal's conversation by id" do
      tokens(alice: "tok-a", bob: "tok-b")
      assert chat("tok-a", [{"x-session-id", "alice-chat"}]).status == 200
      alice_conv = SuperPi.Gateway.Sessions.lookup("alice", "alice-chat")

      conn = chat("tok-b", [{"x-conversation-id", Integer.to_string(alice_conv)}])
      assert conn.status == 200

      # Bob got a fresh conversation that he owns. Alice's was not touched.
      bobs = SuperPi.Durable.Storage.latest_conversation()
      refute bobs.id == alice_conv
      assert Auth.owner(bobs.id) == "bob"
      assert Auth.owner(alice_conv) == "alice"
    end

    test "the owner can attach by id" do
      tokens(alice: "tok-a")
      assert chat("tok-a", [{"x-session-id", "mine"}]).status == 200
      conv = SuperPi.Gateway.Sessions.lookup("alice", "mine")
      assert Auth.authorized?(conv, "alice")
      refute Auth.authorized?(conv, "bob")
    end

    test "a non-loopback bind without a token is refused" do
      assert_raise ArgumentError, ~r/requires a token/, fn ->
        SuperPi.Gateway.Server.child_spec(ip: {0, 0, 0, 0}, port: 0)
      end
    end

    test "a non-loopback bind is accepted once a token is configured" do
      tokens(alice: "tok-a")
      assert %{} = SuperPi.Gateway.Server.child_spec(ip: {0, 0, 0, 0}, port: 0)
    end
  end

  describe "rpc" do
    defp rpc(state, method, params, id \\ 1) do
      payload =
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})

      RPC.handle_rpc_payload(payload, state)
    end

    test "is open with no tokens" do
      {reply, _, _} = rpc(RPC.new_client_state(), "session.open", %{})
      assert %{"result" => %{"conversation_id" => _}} = reply
    end

    test "methods are refused until auth.login succeeds" do
      tokens(alice: "tok-a")
      state = RPC.new_client_state()

      {reply, _, _} = rpc(state, "session.open", %{})
      assert %{"error" => %{"code" => -32001}} = reply

      {reply, ^state, _} = rpc(state, "auth.login", %{"token" => "wrong"})
      assert %{"error" => %{"code" => -32001}} = reply

      {reply, state, _} = rpc(state, "auth.login", %{"token" => "tok-a"})
      assert %{"result" => %{"principal" => "alice"}} = reply

      {reply, _, _} = rpc(state, "session.open", %{})
      assert %{"result" => %{"conversation_id" => _}} = reply
    end

    test "a hand-built client state is not trusted when tokens are configured" do
      tokens(alice: "tok-a")
      {reply, _, _} = rpc(%{}, "session.open", %{})
      assert %{"error" => %{"code" => -32001}} = reply
    end

    test "a conversation owned by another principal looks like a missing one" do
      tokens(alice: "tok-a", bob: "tok-b")

      {_, alice, _} = rpc(RPC.new_client_state(), "auth.login", %{"token" => "tok-a"})
      {_, bob, _} = rpc(RPC.new_client_state(), "auth.login", %{"token" => "tok-b"})

      {%{"result" => %{"conversation_id" => conv}}, _, _} = rpc(alice, "session.open", %{})
      assert Auth.owner(conv) == "alice"

      for method <- [
            "session.open",
            "session.context",
            "session.watch",
            "session.configure",
            "session.compact"
          ] do
        {reply, _, _} =
          rpc(bob, method, %{"conversation_id" => conv, "text" => "x", "agent" => %{}})

        assert %{"error" => %{"code" => -32004}} = reply, "#{method}: #{inspect(reply)}"
      end

      {reply, _, _} = rpc(alice, "session.context", %{"conversation_id" => conv})
      assert %{"result" => _} = reply
    end

    test "a fork belongs to the forking principal" do
      tokens(alice: "tok-a")
      {_, alice, _} = rpc(RPC.new_client_state(), "auth.login", %{"token" => "tok-a"})
      {%{"result" => %{"conversation_id" => conv}}, _, _} = rpc(alice, "session.open", %{})

      entry =
        SuperPi.Durable.Storage.append_entry!(conv, "message", %{
          "role" => "user",
          "content" => "x"
        })

      {%{"result" => %{"conversation_id" => fork}}, _, _} =
        rpc(alice, "session.fork", %{"conversation_id" => conv, "at_entry_id" => entry.id})

      assert Auth.owner(fork) == "alice"
    end
  end

  describe "mcp tools/call" do
    alias SuperPi.MCP.Server, as: MCP

    setup do
      SuperPi.Tools.ensure_catalog_ets!()
      Application.delete_env(:super_pi, :permissions)
      :ok
    end

    defp call_tool(name, args, state \\ %{}) do
      req = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => name, "arguments" => args}
      }

      {:reply, %{"result" => result}, state} = MCP.handle_mcp_line(Jason.encode!(req), state)
      {result, state}
    end

    test "a path outside the workspace is refused" do
      {result, _} = call_tool("read", %{"path" => "/etc/hosts"})
      assert result["isError"] == true
      assert [%{"text" => text}] = result["content"]
      assert text =~ "Blocked"
    end

    test "a path inside the workspace is allowed" do
      {result, _} = call_tool("read", %{"path" => "mix.exs"})
      assert result["isError"] == false
      assert [%{"text" => text}] = result["content"]
      assert text =~ "SuperPi"
    end

    test "bash is blocked in the default remote mode (accept-edits)" do
      {result, _} = call_tool("bash", %{"command" => "echo hi"})
      assert result["isError"] == true
    end

    test "permissions.deny blocks a command" do
      Application.put_env(:super_pi, :permissions,
        remote_max_mode: "auto",
        remote_default_mode: "auto"
      )

      settings = %{"permissions" => %{"deny" => ["command(curl)"]}}

      {_, state} = call_tool("ls", %{"path" => "."})
      conv = state.tool_session.conversation_id
      SuperPi.Durable.Storage.configure_agent!(conv, %{"settingsOverride" => settings})

      {result, _} = call_tool("bash", %{"command" => "curl example.com"}, state)
      assert result["isError"] == true
      assert [%{"text" => text}] = result["content"]
      assert text =~ "permissions.deny"
    end

    test "the connection reuses one policy conversation" do
      {_, state} = call_tool("ls", %{"path" => "."})
      {_, state2} = call_tool("ls", %{"path" => "."}, state)
      assert state.tool_session.conversation_id == state2.tool_session.conversation_id
    end
  end
end
