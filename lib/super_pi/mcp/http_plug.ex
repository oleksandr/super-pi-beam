defmodule SuperPi.MCP.HTTPPlug do
  @moduledoc """
  The MCP server over Streamable HTTP (revisions 2025-03-26 to 2025-06-18), as a Plug.

  `SuperPi.Gateway.Router` forwards `/mcp` here, so the gateway's bearer-token authentication,
  telemetry span, error handling, TLS and listener apply to MCP too. This module adds the MCP
  transport rules on top of the pure engine `SuperPi.MCP.Server.handle_mcp_line/2`.

  | Request | Answer |
  |---|---|
  | `POST` with a request | `200` with the JSON-RPC reply as `application/json`, or as a one-event `text/event-stream` when the client accepts `text/event-stream` and not `application/json` |
  | `POST` with only notifications or responses | `202`, no body |
  | `POST` with `initialize` | as above, plus an `Mcp-Session-Id` header |
  | `GET` | `405`: the server does not push messages, so it opens no stream |
  | `DELETE` | `200`, and the session ends |

  ## Sessions

  `initialize` starts a session (`SuperPi.MCP.Sessions`). Every other request must carry its id in
  `Mcp-Session-Id`: a missing header is `400`, an unknown or expired session is `404`, and a client
  then starts a new one. A session belongs to the principal that opened it. Requests of one session
  that run at the same time each see the state the session had when they began, and the last
  to finish stores its state.

  `initialize?harness=<id>` selects the harness of the session's direct tool calls (see
  `SuperPi.MCP.Server`). An unknown id is `400`.

  ## Checks

  An `MCP-Protocol-Version` header that names a version the server does not speak is `400`. A
  draining node answers `503` with `Retry-After`, so the client reaches another node. When no
  token is configured (`SuperPi.Auth.required?/0` is false), a request with an `Origin` header must
  come from a loopback host or one in `config :super_pi, :mcp_allowed_origins` (`"*"` allows all),
  which stops a web page from calling a local server (DNS rebinding).

  A JSON-RPC batch (an array) is accepted, as 2025-03-26 allows. It must not contain `initialize`.
  """

  @behaviour Plug

  import Plug.Conn

  alias SuperPi.Auth
  alias SuperPi.Harness
  alias SuperPi.MCP.{Server, Sessions}

  @loopback_hosts ["localhost", "127.0.0.1", "::1", "[::1]"]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: []} = conn, _opts) do
    case check_origin(conn) do
      :ok -> route(conn, conn.method)
      {:error, status, message} -> fail(conn, status, message)
    end
  end

  def call(conn, _opts), do: fail(conn, 404, "Not found")

  defp route(conn, "POST"), do: post(conn)
  defp route(conn, "DELETE"), do: delete(conn)

  defp route(conn, _other) do
    conn
    |> put_resp_header("allow", "POST, DELETE")
    |> fail(405, "Method not allowed: this server sends no messages on its own")
  end

  # --- POST ---

  defp post(conn) do
    with :ok <- check_draining(),
         :ok <- check_version(conn),
         {:ok, messages, batch?, conn} <- read_messages(conn),
         {:ok, session_id, state, new?} <- open_session(conn, messages) do
      {replies, state, ended?} = process(messages, state)

      if ended?, do: Sessions.delete(session_id), else: Sessions.put(session_id, state)

      conn = if new?, do: put_resp_header(conn, "mcp-session-id", session_id), else: conn
      respond(conn, replies, batch?)
    else
      {:error, status, message} -> fail(conn, status, message)
      {:error, status, message, conn} -> fail(conn, status, message)
    end
  end

  defp check_draining do
    if SuperPi.Drain.accepting?(),
      do: :ok,
      else: {:error, 503, "This node is shutting down. Retry the request."}
  end

  defp check_version(conn) do
    case get_req_header(conn, "mcp-protocol-version") do
      [] ->
        :ok

      [version | _] ->
        if version in Server.supported_versions(),
          do: :ok,
          else: {:error, 400, "Unsupported MCP-Protocol-Version: #{version}"}
    end
  end

  # The router parses a JSON body before it dispatches. Used on its own, this plug reads it.
  defp read_messages(conn) do
    case conn.body_params do
      %Plug.Conn.Unfetched{} ->
        with {:ok, raw, conn} <- read_body(conn),
             {:ok, decoded} <- Jason.decode(raw) do
          messages(decoded, conn)
        else
          _ -> {:error, 400, "Parse error: the body is not JSON", conn}
        end

      %{"_json" => list} when is_list(list) ->
        messages(list, conn)

      %{"_json" => other} ->
        messages(other, conn)

      %{} = params ->
        messages(params, conn)
    end
  end

  defp messages([], conn), do: {:error, 400, "Invalid Request: an empty batch", conn}
  defp messages(list, conn) when is_list(list), do: {:ok, list, true, conn}
  defp messages(%{} = message, conn), do: {:ok, [message], false, conn}

  defp messages(_other, conn),
    do: {:error, 400, "Invalid Request: expected a JSON-RPC object or array", conn}

  defp open_session(conn, messages) do
    initializes = Enum.count(messages, &initialize?/1)

    cond do
      initializes > 1 or (initializes == 1 and length(messages) > 1) ->
        {:error, 400, "initialize must be sent alone"}

      initializes == 1 ->
        start_session(conn)

      true ->
        find_session(conn)
    end
  end

  defp initialize?(%{"method" => "initialize"}), do: true
  defp initialize?(_), do: false

  defp start_session(conn) do
    principal = conn.assigns[:principal] || Auth.anonymous()
    conn = fetch_query_params(conn)

    with {:ok, harness} <- requested_harness(conn.query_params["harness"]),
         {:ok, id} <- Sessions.create(session_state(principal, harness)) do
      {:ok, id, session_state(principal, harness), true}
    else
      {:error, :full} -> {:error, 503, "Too many MCP sessions"}
      {:error, status, message} -> {:error, status, message}
    end
  end

  defp session_state(principal, nil), do: %{principal: principal}
  defp session_state(principal, harness), do: %{principal: principal, harness: harness}

  defp requested_harness(nil), do: {:ok, nil}

  defp requested_harness(name) when is_binary(name) do
    case Harness.fetch(name) do
      {:ok, harness} -> {:ok, harness.id()}
      {:error, _} -> {:error, 400, "Unknown harness: #{name}"}
    end
  end

  defp requested_harness(_), do: {:error, 400, "Unknown harness"}

  defp find_session(conn) do
    case get_req_header(conn, "mcp-session-id") do
      [] ->
        {:error, 400, "Missing Mcp-Session-Id header: send initialize first"}

      [id | _] ->
        principal = conn.assigns[:principal] || Auth.anonymous()

        # A session of another principal is reported as unknown, so its id tells nothing.
        case Sessions.fetch(id) do
          {:ok, %{principal: ^principal} = state} -> {:ok, id, state, false}
          _ -> {:error, 404, "Unknown or expired session: send initialize again"}
        end
    end
  end

  # Runs the messages in order through the pure engine. Responses from the client carry no
  # method: they are accepted and need no answer, so they never reach the engine.
  defp process(messages, state) do
    Enum.reduce(messages, {[], state, false}, fn message, {replies, state, ended?} ->
      case classify(message) do
        :response ->
          {replies, state, ended?}

        kind ->
          case Server.handle_mcp_line(Jason.encode!(message), state) do
            {:reply, reply, state} ->
              {if(kind == :request or invalid?(reply), do: [reply | replies], else: replies),
               state, ended?}

            {:noreply, state} ->
              {replies, state, ended?}

            {:stop, _reason, state} ->
              {replies, state, true}
          end
      end
    end)
    |> then(fn {replies, state, ended?} -> {Enum.reverse(replies), state, ended?} end)
  end

  defp classify(%{"method" => method} = message) when is_binary(method) do
    if Map.get(message, "id") == nil, do: :notification, else: :request
  end

  defp classify(%{"id" => _} = message) do
    if Map.has_key?(message, "result") or Map.has_key?(message, "error"),
      do: :response,
      else: :invalid
  end

  defp classify(_), do: :invalid

  defp invalid?(%{"error" => %{"code" => code}}), do: code in [-32700, -32600]
  defp invalid?(_), do: false

  defp respond(conn, [], _batch?), do: send_resp(conn, 202, "")

  defp respond(conn, replies, batch?) do
    body = if batch?, do: replies, else: hd(replies)
    status = if not batch? and invalid?(hd(replies)), do: 400, else: 200
    if event_stream?(conn), do: stream(conn, status, body), else: json(conn, status, body)
  end

  # A client that lists only `text/event-stream` asks for the reply as an event. One that lists
  # `application/json` too (the spec requires both) gets plain JSON.
  defp event_stream?(conn) do
    accept = conn |> get_req_header("accept") |> Enum.join(",")

    String.contains?(accept, "text/event-stream") and
      not String.contains?(accept, "application/json")
  end

  defp stream(conn, status, body) do
    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> send_chunked(status)

    case chunk(conn, "event: message\ndata: " <> Jason.encode!(body) <> "\n\n") do
      {:ok, conn} -> conn
      {:error, _closed} -> conn
    end
  end

  # --- DELETE ---

  defp delete(conn) do
    case get_req_header(conn, "mcp-session-id") do
      [] ->
        fail(conn, 400, "Missing Mcp-Session-Id header")

      [id | _] ->
        principal = conn.assigns[:principal] || Auth.anonymous()

        case Sessions.fetch(id) do
          {:ok, %{principal: ^principal}} ->
            Sessions.delete(id)
            send_resp(conn, 200, "")

          _ ->
            fail(conn, 404, "Unknown or expired session")
        end
    end
  end

  # --- Origin ---

  defp check_origin(conn) do
    case get_req_header(conn, "origin") do
      [] ->
        :ok

      [origin | _] ->
        if Auth.required?() or origin_allowed?(origin),
          do: :ok,
          else: {:error, 403, "Origin not allowed: #{origin}"}
    end
  end

  defp origin_allowed?(origin) do
    allowed = List.wrap(Application.get_env(:super_pi, :mcp_allowed_origins, []))
    host = URI.parse(origin).host

    "*" in allowed or origin in allowed or host in @loopback_hosts
  end

  # --- Responses ---

  defp json(conn, status, body) do
    conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
  end

  # A transport-level failure. It is a JSON-RPC error with no id, as the spec shows for these.
  defp fail(conn, status, message) do
    body = %{
      "jsonrpc" => "2.0",
      "id" => nil,
      "error" => %{"code" => error_code(status), "message" => message}
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end

  defp error_code(400), do: -32600
  defp error_code(404), do: -32001
  defp error_code(_), do: -32000
end
