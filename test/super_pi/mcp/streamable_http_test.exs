defmodule SuperPi.MCP.StreamableHTTPTest do
  @moduledoc "Client over Streamable HTTP (and the HTTP+SSE fallback) against `FakeHTTPMCP`."
  use SuperPi.DataCase, async: false

  alias SuperPi.Durable.{Doc, Storage}
  alias SuperPi.MCP.{Client, Manager}
  alias SuperPi.MCP.Transport.StreamableHTTP
  alias SuperPi.Plugins.Permissions
  alias SuperPi.TestSupport.FakeHTTPMCP, as: Fake
  alias SuperPi.Tools

  @token_var "SUPER_PI_FAKE_MCP_TOKEN"

  setup do
    Tools.ensure_catalog_ets!()
    Manager.create_tables()
    Manager.stop_all()
    on_exit(&Manager.stop_all/0)

    System.put_env(@token_var, "s3cret")
    on_exit(fn -> System.delete_env(@token_var) end)

    dir = Path.join(System.tmp_dir!(), "mcp_http_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  defp server(opts \\ []) do
    {:ok, fake} = Fake.start(opts)
    on_exit(fn -> Fake.stop(fake) end)
    fake
  end

  defp client(fake, extra \\ []) do
    {:ok, pid} = Client.start_link([name: "http", url: fake.url] ++ extra)
    pid
  end

  defp header(request, name), do: request.headers[name]

  describe "JSON responses" do
    test "handshake, tool listing and a call; the session id and version are carried" do
      fake = server()
      pid = client(fake)

      assert :ok = Client.await_ready(pid, 5_000)

      assert pid |> Client.tools() |> Enum.map(& &1["name"]) == [
               "echo",
               "mutate",
               "stream",
               "silent"
             ]

      assert {:ok, %{"content" => [%{"text" => "echo: hi"}]}} =
               Client.call_tool(pid, "echo", %{"text" => "hi"})

      # `initialized` reaches the server before the first request that follows it.
      assert fake |> Fake.requests() |> Enum.map(& &1.body["method"]) ==
               ["initialize", "notifications/initialized", "tools/list", "tools/call"]

      [init] = Fake.requests(fake, "initialize")
      assert init.body["params"]["protocolVersion"] == "2025-06-18"
      assert header(init, "mcp-session-id") == nil
      assert header(init, "accept") =~ "text/event-stream"

      later = fake |> Fake.requests() |> Enum.reject(&(&1.body["method"] == "initialize"))
      assert length(later) == 3
      assert Enum.all?(later, &(header(&1, "mcp-session-id") == "sess-1"))
      assert Enum.all?(later, &(header(&1, "mcp-protocol-version") == "2025-06-18"))
    end

    test "the version the server answers is the one sent on later requests" do
      fake = server(version: "2025-03-26")
      pid = client(fake)
      assert :ok = Client.await_ready(pid, 5_000)

      [list] = Fake.requests(fake, "tools/list")
      assert header(list, "mcp-protocol-version") == "2025-03-26"
    end

    test "a notification is answered 202 with no body and the client stays ready" do
      fake = server()
      pid = client(fake)
      assert :ok = Client.await_ready(pid, 5_000)

      assert [%{body: %{"method" => "notifications/initialized"}}] =
               Fake.requests(fake, "notifications/initialized")

      assert {:ok, _} = Client.call_tool(pid, "echo", %{"text" => "after"})
    end

    test "a request that gets 202 instead of an answer fails at once, not at its timeout" do
      fake = server()
      pid = client(fake)
      :ok = Client.await_ready(pid, 5_000)

      started = System.monotonic_time(:millisecond)

      assert {:error, {:protocol_error, %{"message" => message}}} =
               Client.call_tool(pid, "silent", %{}, 30_000)

      assert message =~ "no response"
      assert System.monotonic_time(:millisecond) - started < 5_000
    end

    test "a JSON-RPC error is a protocol error" do
      fake = server()
      pid = client(fake)
      :ok = Client.await_ready(pid, 5_000)

      assert {:error, {:protocol_error, %{"message" => "unknown method tools/call"}}} =
               Client.call_tool(pid, "nope", %{})
    end
  end

  describe "event-stream responses" do
    test "a tool answered as text/event-stream, with a progress notification first and split chunks" do
      fake = server()
      pid = client(fake)
      :ok = Client.await_ready(pid, 5_000)

      assert {:ok,
              %{"content" => [%{"text" => "stream done"}], "structuredContent" => %{"ok" => true}}} =
               Client.call_tool(pid, "stream", %{})
    end

    test "every response, the handshake included, as an event stream" do
      fake = server(sse_all: true)
      pid = client(fake)
      assert :ok = Client.await_ready(pid, 5_000)

      assert {:ok, %{"content" => [%{"text" => "echo: sse"}]}} =
               Client.call_tool(pid, "echo", %{"text" => "sse"})
    end
  end

  describe "session" do
    test "a 404 starts a new session and repeats the request once" do
      fake = server()
      pid = client(fake)
      :ok = Client.await_ready(pid, 5_000)

      Fake.expire_sessions(fake)

      assert {:ok, %{"content" => [%{"text" => "echo: again"}]}} =
               Client.call_tool(pid, "echo", %{"text" => "again"})

      assert length(Fake.requests(fake, "initialize")) == 2
      assert length(Fake.requests(fake, "notifications/initialized")) == 2
      calls = Fake.requests(fake, "tools/call")
      assert Enum.map(calls, &header(&1, "mcp-session-id")) == ["sess-1", "sess-2"]

      # The new session is kept for the next call.
      assert {:ok, _} = Client.call_tool(pid, "echo", %{"text" => "third"})
      assert length(Fake.requests(fake, "initialize")) == 2

      assert fake |> Fake.requests("tools/call") |> List.last() |> header("mcp-session-id") ==
               "sess-2"
    end

    test "stopping the client ends the session with a DELETE" do
      fake = server()
      pid = client(fake)
      :ok = Client.await_ready(pid, 5_000)

      GenServer.stop(pid)
      assert eventually(fn -> Enum.any?(Fake.requests(fake), &(&1.method == "DELETE")) end)
      delete = Enum.find(Fake.requests(fake), &(&1.method == "DELETE"))
      assert header(delete, "mcp-session-id") == "sess-1"
    end
  end

  describe "fallback to HTTP+SSE" do
    test "405 on the first POST opens the event stream and posts to the announced endpoint" do
      fake = server(legacy: true)
      pid = client(fake, url: fake.base <> "/mcp")
      assert :ok = Client.await_ready(pid, 5_000)

      assert {:ok, %{"content" => [%{"text" => "echo: legacy"}]}} =
               Client.call_tool(pid, "echo", %{"text" => "legacy"})

      requests = Fake.requests(fake)

      assert requests |> Enum.map(&{&1.method, &1.path}) |> Enum.take(2) == [
               {"POST", "/mcp"},
               {"GET", "/mcp"}
             ]

      assert Enum.any?(requests, &(&1.method == "POST" and &1.path == "/messages"))
    end

    test "an endpoint on another origin is refused" do
      fake = server(legacy: true, endpoint: "http://evil.example.test/messages")
      Process.flag(:trap_exit, true)
      pid = client(fake, url: fake.base <> "/sse")

      # The URL of a legacy server is its event stream: a POST to it is a 404, which also falls back.
      assert {:error, _} = Client.await_ready(pid, 5_000)
      refute Enum.any?(Fake.requests(fake), &(&1.path == "/messages"))
    end
  end

  describe "headers" do
    test "${ENV_VAR} is expanded and a header name is case-insensitive" do
      fake = server(require: {"authorization", "Bearer s3cret"})

      pid =
        client(fake, headers: %{"Authorization" => "Bearer ${#{@token_var}}", "X-Plain" => "yes"})

      assert :ok = Client.await_ready(pid, 5_000)

      [init | _] = Fake.requests(fake)
      assert header(init, "authorization") == "Bearer s3cret"
      assert header(init, "x-plain") == "yes"
    end

    test "a missing variable fails the start and names the variable" do
      fake = server()
      Process.flag(:trap_exit, true)

      assert {:error, {:missing_env, ["SUPER_PI_NOT_SET_A", "SUPER_PI_NOT_SET_B"]}} =
               Client.start_link(
                 name: "x",
                 url: fake.url,
                 headers: %{"a" => "${SUPER_PI_NOT_SET_B}", "b" => "x ${SUPER_PI_NOT_SET_A}"}
               )

      assert Fake.requests(fake) == []
    end

    test "expand_env/1" do
      System.put_env("SUPER_PI_E1", "one")
      on_exit(fn -> System.delete_env("SUPER_PI_E1") end)

      assert {:ok, "a-one-one"} = StreamableHTTP.expand_env("a-${SUPER_PI_E1}-${SUPER_PI_E1}")
      assert {:ok, "plain"} = StreamableHTTP.expand_env("plain")
      assert {:ok, "5"} = StreamableHTTP.expand_env(5)
      assert {:missing, ["SUPER_PI_E_NOPE"]} = StreamableHTTP.expand_env("${SUPER_PI_E_NOPE}")
      assert :invalid = StreamableHTTP.expand_env(%{})
    end

    test "a wrong token is a handshake error that carries the status" do
      fake = server(require: {"authorization", "Bearer other"})
      pid = client(fake, headers: %{"authorization" => "Bearer s3cret"})

      assert {:error, {:handshake_failed, %{"message" => "HTTP 401" <> _}}} =
               Client.await_ready(pid, 5_000)
    end
  end

  describe "bad entries" do
    test "an invalid URL" do
      Process.flag(:trap_exit, true)

      assert {:error, {:invalid_url, "ftp://example.com"}} =
               Client.start_link(name: "x", url: "ftp://example.com")

      assert {:error, {:invalid_url, "not a url"}} =
               Client.start_link(name: "x", url: "not a url")
    end

    test "a server that is not listening" do
      fake = server()
      Fake.stop(fake)
      pid = client(fake)

      assert {:error, {:handshake_failed, %{"message" => message}}} =
               Client.await_ready(pid, 5_000)

      assert is_binary(message)
    end
  end

  describe "Manager" do
    defp write_config(dir, servers) do
      File.write!(Path.join(dir, "mcp_config.json"), Jason.encode!(%{"mcpServers" => servers}))
    end

    test "starts a url entry, registers its tools with effects and routes a call", %{dir: dir} do
      fake = server(require: {"authorization", "Bearer s3cret"})

      write_config(dir, %{
        "hosted" => %{
          "url" => fake.url,
          "headers" => %{"Authorization" => "Bearer ${#{@token_var}}"}
        },
        "alias" => %{
          "serverUrl" => fake.url,
          "headers" => %{"Authorization" => "Bearer ${#{@token_var}}"}
        }
      })

      results = Manager.ensure_started(global_config_dir: dir)
      assert Enum.all?(results, &(&1.status == :started and &1.tools == 4))

      assert Tools.effects("mcp__hosted__echo") == ["net_read"]
      assert Tools.effects("mcp__hosted__mutate") == ["net_write"]
      assert Tools.effects("mcp__hosted__stream") == ["net_write"]

      assert %{"output" => "echo: hi", "is_error" => false} =
               Tools.execute("mcp__hosted__echo", %{"text" => "hi"})

      assert %{"structured_output" => %{"ok" => true}} = Tools.execute("mcp__hosted__mutate", %{})
    end

    test "a url entry with a missing variable is reported and skipped", %{dir: dir} do
      fake = server()

      write_config(dir, %{
        "hosted" => %{"url" => fake.url, "headers" => %{"x" => "${SUPER_PI_NOT_SET_C}"}}
      })

      assert [%{status: {:error, {:missing_env, ["SUPER_PI_NOT_SET_C"]}}, tools: 0}] =
               Manager.ensure_started(global_config_dir: dir)
    end

    test "stop_all stops an HTTP client", %{dir: dir} do
      fake = server()
      write_config(dir, %{"hosted" => %{"url" => fake.url}})
      assert [%{status: :started}] = Manager.ensure_started(global_config_dir: dir)
      Manager.stop_all()
      assert Manager.tool_names() == []
      assert eventually(fn -> Enum.any?(Fake.requests(fake), &(&1.method == "DELETE")) end)
    end

    test "the permission layer decides by the effects", %{dir: dir} do
      fake = server()
      write_config(dir, %{"hosted" => %{"url" => fake.url}})
      Manager.ensure_started(global_config_dir: dir)

      decide = fn mode, tool -> Permissions.decide(tool, %{}, %{"executionMode" => mode}, %{}) end

      # Read-only: no prompt in accept-edits, allowed in plan.
      assert :allow = decide.("accept-edits", "mcp__hosted__echo")
      assert :allow = decide.("plan", "mcp__hosted__echo")
      # No annotation: a network write.
      assert {:block, _} = decide.("accept-edits", "mcp__hosted__mutate")
      assert {:block, _} = decide.("plan", "mcp__hosted__mutate")
      assert :allow = decide.("auto", "mcp__hosted__mutate")
      # The network policy covers MCP tools.
      assert {:block, _} =
               Permissions.decide("mcp__hosted__echo", %{}, %{"executionMode" => "auto"}, %{
                 "network" => "deny"
               })
    end

    test "the CLI writes a url entry that the manager starts", %{dir: dir} do
      fake = server()
      assert {0, _} = SuperPi.CLI.run(["mcp", "add", "hosted", fake.url], global_config_dir: dir)

      assert %{"mcpServers" => %{"hosted" => %{"url" => url} = spec}} =
               dir |> Path.join("mcp_config.json") |> File.read!() |> Jason.decode!()

      assert url == fake.url
      refute Map.has_key?(spec, "command")

      assert [%{name: "hosted", type: "http"}] =
               SuperPi.Plugins.TranscriptLogger.mcp_list(global_config_dir: dir)

      assert [%{status: :started, tools: 4}] = Manager.ensure_started(global_config_dir: dir)
    end
  end

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(50) && eventually(fun, tries - 1)
    end
  end

  describe "servers handed over at run time (ACP mcpServers)" do
    defp conversation, do: Storage.create_conversation!(agent: %{"model" => "m"}).id

    defp acp_server(fake, value) do
      %{
        "type" => "http",
        "name" => "acp-http",
        "url" => fake.url,
        "headers" => [%{"name" => "x-test", "value" => value}]
      }
    end

    defp declared(conv_id) do
      (Doc.snapshot("conversation", conv_id, "pi.agent") || %{})
      |> Map.get("tools", [])
      |> Enum.map(& &1["name"])
    end

    test "an HTTP server with header pairs is started and its tools are declared for the conversation" do
      fake = server()
      conv_id = conversation()

      assert [%{server: "acp-http", status: :started, tools: tools}] =
               Manager.add_servers(conv_id, [acp_server(fake, "1")])

      assert tools > 0
      assert "mcp__acp-http__echo" in Manager.tool_names(conv_id)
      assert "mcp__acp-http__echo" in declared(conv_id)
      assert Fake.requests(fake) |> Enum.any?(&(header(&1, "x-test") == "1"))
    end

    test "another conversation neither sees nor reaches the tools" do
      fake = server()
      [a, b] = [conversation(), conversation()]
      Manager.add_servers(a, [acp_server(fake, "1")])
      Manager.declare_tools(b)

      assert Manager.tool_names() == []
      refute Enum.any?(Tools.active_llm_tools(), &(&1["name"] == "mcp__acp-http__echo"))
      refute "mcp__acp-http__echo" in declared(b)

      assert %{"is_error" => true, "output" => output} =
               Manager.call_tool("mcp__acp-http__echo", %{"text" => "hi"}, b)

      assert output =~ "not available"

      assert %{"is_error" => false} =
               Manager.call_tool("mcp__acp-http__echo", %{"text" => "hi"}, a)
    end

    test "two conversations with a same-named server get one process each, with their own headers" do
      fake = server()
      [a, b] = [conversation(), conversation()]

      assert [%{status: :started}] = Manager.add_servers(a, [acp_server(fake, "a")])
      assert [%{status: :started}] = Manager.add_servers(b, [acp_server(fake, "b")])
      assert [%{status: :running}] = Manager.add_servers(b, [acp_server(fake, "b")])

      Manager.call_tool("mcp__acp-http__echo", %{"text" => "hi"}, b)

      calls = Fake.requests(fake, "tools/call")
      assert [%{} = call] = calls
      assert header(call, "x-test") == "b"
    end

    test "stop_scope stops the conversation's servers and leaves the others running" do
      fake = server()
      [a, b] = [conversation(), conversation()]
      Manager.add_servers(a, [acp_server(fake, "a")])
      Manager.add_servers(b, [acp_server(fake, "b")])

      Manager.stop_scope(a)

      assert Manager.tool_names(a) == []
      assert "mcp__acp-http__echo" in Manager.tool_names(b)

      assert %{"is_error" => true} =
               Manager.call_tool("mcp__acp-http__echo", %{"text" => "hi"}, a)
    end

    test "an entry with no name or no way to start is skipped, a bad one does not raise" do
      conv_id = conversation()
      assert [] = Manager.add_servers(conv_id, [%{"command" => "x"}, %{"name" => ""}])

      assert [%{status: {:error, :no_command_or_url}}] =
               Manager.add_servers(conv_id, [%{"name" => "nothing"}])
    end
  end
end
