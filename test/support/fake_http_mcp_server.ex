defmodule SuperPi.TestSupport.FakeHTTPMCP do
  @moduledoc """
  A fake MCP server over HTTP for the client transport tests (Bandit and Plug, loopback, random port).

  Streamable HTTP lives at `/mcp`. It issues an `Mcp-Session-Id` on `initialize` and answers
  `404` to a request that carries an unknown session. Tools: `echo` (annotated `readOnlyHint`),
  `mutate` (no annotation), `stream` (answered as `text/event-stream`, with a progress
  notification before the result) and `silent` (answered `202`, which is a protocol violation).

  Options of `start/1`:

    * `:legacy` - the deprecated HTTP+SSE transport: `POST /mcp` is `405`, `GET /sse` opens the
      stream, `POST /messages` takes the messages and the answers arrive on the stream.
    * `:sse_all` - every request is answered as an event stream.
    * `:require` - `{header, value}` that a request must carry, else `401`.
    * `:endpoint` - what the legacy `endpoint` event announces (default `/messages?sessionId=...`).
    * `:version` - the `protocolVersion` to answer with (default: the client's).

  `requests/1` returns what the server saw, oldest first, as `%{method, path, headers, body}`.
  """

  import Plug.Conn

  defstruct [:url, :base, :store, :server]

  def start(opts \\ []) do
    {:ok, store} =
      Agent.start_link(fn ->
        %{opts: Map.new(opts), sessions: MapSet.new(), log: [], streams: %{}, next: 1}
      end)

    {:ok, server} =
      Bandit.start_link(
        plug: {__MODULE__.Router, store},
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    base = "http://127.0.0.1:#{port}"
    {:ok, %__MODULE__{url: base <> "/mcp", base: base, store: store, server: server}}
  end

  def stop(%__MODULE__{store: store, server: server}) do
    for pid <- [server, store], Process.alive?(pid), do: Process.exit(pid, :normal)
    :ok
  end

  def requests(%__MODULE__{store: store}), do: store |> Agent.get(& &1.log) |> Enum.reverse()

  @doc "Requests whose JSON-RPC `method` is `method`, oldest first."
  def requests(%__MODULE__{} = server, method) do
    Enum.filter(requests(server), &(rpc_method(&1) == method))
  end

  def rpc_method(%{body: %{"method" => method}}), do: method
  def rpc_method(_), do: nil

  @doc "Forgets every session, as a server that restarted or timed a session out."
  def expire_sessions(%__MODULE__{store: store}),
    do: Agent.update(store, &%{&1 | sessions: MapSet.new()})

  defmodule Router do
    @moduledoc false
    import Plug.Conn

    def init(store), do: store

    # A client may still close its session after the test stopped the server.
    def call(conn, store) do
      handle(conn, store)
    catch
      :exit, _ -> send_resp(conn, 503, "server stopped")
    end

    defp handle(conn, store) do
      {:ok, raw, conn} = read_body(conn)
      body = with {:ok, decoded} <- Jason.decode(raw), do: decoded, else: (_ -> raw)
      headers = Map.new(conn.req_headers)

      Agent.update(store, fn s ->
        %{
          s
          | log: [
              %{
                method: conn.method,
                path: conn.request_path,
                query: conn.query_string,
                headers: headers,
                body: body
              }
              | s.log
            ]
        }
      end)

      opts = Agent.get(store, & &1.opts)

      with {name, value} <- opts[:require], true <- headers[name] != value do
        send_resp(conn, 401, "unauthorized")
      else
        _ -> route(conn, conn.method, conn.request_path, body, store, opts)
      end
    end

    # --- Streamable HTTP ---

    defp route(conn, "POST", "/mcp", _body, _store, %{legacy: true}),
      do: send_resp(conn, 405, "use the SSE endpoint")

    defp route(conn, "POST", "/mcp", body, store, opts), do: post(conn, body, store, opts)
    defp route(conn, "DELETE", "/mcp", _body, store, _opts), do: end_session(conn, store)

    # --- HTTP+SSE ---

    # The stream is at the URL the client was given, as on a deployed legacy server.
    defp route(conn, "GET", path, _body, store, %{legacy: true} = opts)
         when path in ["/mcp", "/sse"] do
      id = "legacy-#{System.unique_integer([:positive])}"
      me = self()
      Agent.update(store, fn s -> %{s | streams: Map.put(s.streams, id, me)} end)
      endpoint = opts[:endpoint] || "/messages?sessionId=#{id}"

      conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)
      {:ok, conn} = chunk(conn, "event: endpoint\ndata: #{endpoint}\n\n")
      stream_loop(conn)
    end

    defp route(conn, "POST", "/messages", body, store, %{legacy: true}) do
      id = URI.decode_query(conn.query_string)["sessionId"]

      with pid when is_pid(pid) <- Agent.get(store, &Map.get(&1.streams, id)),
           %{"id" => _} = request <- body,
           {:ok, result} <- rpc(request, store) do
        send(
          pid,
          {:push, Jason.encode!(%{"jsonrpc" => "2.0", "id" => request["id"], "result" => result})}
        )
      end

      send_resp(conn, 202, "")
    end

    defp route(conn, "GET", "/mcp", _body, _store, _opts), do: send_resp(conn, 405, "no stream")
    defp route(conn, _method, _path, _body, _store, _opts), do: send_resp(conn, 404, "not found")

    defp stream_loop(conn) do
      receive do
        {:push, json} ->
          {:ok, conn} = chunk(conn, "event: message\ndata: #{json}\n\n")
          stream_loop(conn)
      after
        30_000 -> conn
      end
    end

    # --- POST /mcp ---

    defp post(conn, %{"method" => "initialize", "id" => id, "params" => params}, store, opts) do
      session =
        Agent.get_and_update(store, fn s ->
          sid = "sess-#{s.next}"
          {sid, %{s | next: s.next + 1, sessions: MapSet.put(s.sessions, sid)}}
        end)

      result = %{
        "protocolVersion" => opts[:version] || params["protocolVersion"],
        "capabilities" => %{"tools" => %{}},
        "serverInfo" => %{"name" => "fake-http", "version" => "1.0.0"}
      }

      conn
      |> put_resp_header("mcp-session-id", session)
      |> reply(%{"jsonrpc" => "2.0", "id" => id, "result" => result}, opts)
    end

    defp post(conn, body, store, opts) do
      case check_session(conn, store) do
        :ok -> dispatch(conn, body, store, opts)
        {:error, status, text} -> send_resp(conn, status, text)
      end
    end

    defp check_session(conn, store) do
      case get_req_header(conn, "mcp-session-id") do
        [] ->
          {:error, 400, "missing session"}

        [sid | _] ->
          if Agent.get(store, &MapSet.member?(&1.sessions, sid)),
            do: :ok,
            else: {:error, 404, "unknown session"}
      end
    end

    # A notification or a response from the client: accepted, no body.
    defp dispatch(conn, %{"method" => _} = body, _store, _opts) when not is_map_key(body, "id"),
      do: send_resp(conn, 202, "")

    defp dispatch(conn, %{"result" => _}, _store, _opts), do: send_resp(conn, 202, "")

    defp dispatch(
           conn,
           %{"method" => "tools/call", "params" => %{"name" => "silent"}},
           _store,
           _opts
         ),
         do: send_resp(conn, 202, "")

    defp dispatch(
           conn,
           %{"method" => "tools/call", "id" => id, "params" => %{"name" => "stream"}} = body,
           store,
           opts
         ) do
      progress = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/progress",
        "params" => %{"progress" => 1}
      }

      {:ok, result} = rpc(body, store)
      stream(conn, [progress, %{"jsonrpc" => "2.0", "id" => id, "result" => result}], opts)
    end

    defp dispatch(conn, %{"id" => id} = body, store, opts) do
      message =
        case rpc(body, store) do
          {:ok, result} -> %{"jsonrpc" => "2.0", "id" => id, "result" => result}
          {:error, error} -> %{"jsonrpc" => "2.0", "id" => id, "error" => error}
        end

      reply(conn, message, opts)
    end

    defp reply(conn, message, %{sse_all: true}), do: stream(conn, [message], %{})

    defp reply(conn, message, _opts) do
      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(message))
    end

    # Each event is sent in two chunks, cut inside the JSON, so a client must buffer.
    defp stream(conn, messages, _opts) do
      conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)

      Enum.reduce(messages, conn, fn message, conn ->
        event = "event: message\r\ndata: " <> Jason.encode!(message) <> "\r\n\r\n"
        cut = div(byte_size(event), 2)
        {:ok, conn} = chunk(conn, binary_part(event, 0, cut))
        Process.sleep(5)
        {:ok, conn} = chunk(conn, binary_part(event, cut, byte_size(event) - cut))
        conn
      end)
    end

    defp end_session(conn, store) do
      case get_req_header(conn, "mcp-session-id") do
        [sid | _] ->
          Agent.update(store, fn s -> %{s | sessions: MapSet.delete(s.sessions, sid)} end)

        [] ->
          :ok
      end

      send_resp(conn, 200, "")
    end

    # --- JSON-RPC ---

    # Only the legacy transport gets here: a streamable `initialize` is answered in `post/4`.
    defp rpc(%{"method" => "initialize", "params" => params}, _store) do
      {:ok,
       %{
         "protocolVersion" => params["protocolVersion"],
         "capabilities" => %{"tools" => %{}},
         "serverInfo" => %{"name" => "fake-legacy", "version" => "1.0.0"}
       }}
    end

    defp rpc(%{"method" => "tools/list"}, _store) do
      {:ok,
       %{
         "tools" => [
           %{
             "name" => "echo",
             "description" => "Echo the text",
             "inputSchema" => %{
               "type" => "object",
               "properties" => %{"text" => %{"type" => "string"}}
             },
             "annotations" => %{"readOnlyHint" => true}
           },
           %{
             "name" => "mutate",
             "description" => "Changes things",
             "inputSchema" => %{"type" => "object", "properties" => %{}}
           },
           %{
             "name" => "stream",
             "description" => "Streams",
             "inputSchema" => %{"type" => "object", "properties" => %{}},
             "annotations" => %{"readOnlyHint" => false}
           },
           %{
             "name" => "silent",
             "description" => "Never answers",
             "inputSchema" => %{"type" => "object", "properties" => %{}}
           }
         ]
       }}
    end

    defp rpc(
           %{"method" => "tools/call", "params" => %{"name" => "echo", "arguments" => args}},
           _store
         ) do
      {:ok, %{"content" => [%{"type" => "text", "text" => "echo: " <> to_string(args["text"])}]}}
    end

    defp rpc(%{"method" => "tools/call", "params" => %{"name" => name}}, _store)
         when name in ["mutate", "stream"] do
      {:ok,
       %{
         "content" => [%{"type" => "text", "text" => "#{name} done"}],
         "structuredContent" => %{"ok" => true}
       }}
    end

    defp rpc(%{"method" => "ping"}, _store), do: {:ok, %{}}

    defp rpc(%{"method" => method}, _store),
      do: {:error, %{"code" => -32601, "message" => "unknown method " <> method}}
  end
end
