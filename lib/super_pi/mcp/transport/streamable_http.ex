defmodule SuperPi.MCP.Transport.StreamableHTTP do
  @moduledoc """
  Streamable HTTP transport (MCP 2025-03-26 and later) on `Finch`, with the deprecated
  HTTP+SSE transport (2024-11-05) as a fallback.

  Every JSON-RPC message the client sends is one `POST` to the server URL, made by its own
  short-lived process so a slow tool call never blocks the next request. The server answers in
  one of three shapes, and the transport handles each:

    * `202 Accepted` with no body: the message was a notification or a response.
    * `application/json`: one JSON-RPC message, or an array of them.
    * `text/event-stream`: SSE events, each carrying a JSON-RPC message. They are delivered as
      they arrive, so a server can send progress and its own requests before the result.

  ## Session

  A server that keeps state returns an `Mcp-Session-Id` header on the `initialize` response. The
  transport sends it on every later request, and the negotiated version as `MCP-Protocol-Version`.
  When the server answers a request with `404` (it dropped the session), the transport runs the
  handshake again once and repeats the request. On close it sends a `DELETE` to end the session.

  ## Fallback to HTTP+SSE

  A server that only speaks the 2024-11-05 transport answers the first `POST` with `405` (or
  `404`). The transport then opens a `GET` event stream to the same URL, waits for the `endpoint`
  event, and `POST`s every message to that endpoint. Answers arrive on the stream. An endpoint on
  another origin is refused, so a hostile server cannot aim the client at a third host.

  ## Headers

  The `:headers` option is a map of request headers. A value may contain `${ENV_VAR}`, which is
  replaced from the environment when the transport starts. A variable that is not set is an
  error, so a missing token fails at once instead of as a `401`. OAuth is not implemented: put a
  bearer token in `Authorization`.

  The `SuperPi.MCPFinch` pool must be running (the application starts it).
  """

  @behaviour SuperPi.MCP.Transport

  require Logger

  @pool SuperPi.MCPFinch
  @protocol_version "2025-06-18"
  @default_receive_timeout 120_000
  @max_body 16 * 1024 * 1024
  @env_ref ~r/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/

  defstruct [
    :url,
    :session_id,
    :protocol_version,
    :init_message,
    :endpoint,
    :sse,
    headers: [],
    mode: :streamable,
    queue: [],
    tasks: %{},
    acks: %{},
    receive_timeout: @default_receive_timeout
  ]

  @impl true
  def protocol_version, do: @protocol_version

  @doc """
  Options: `:url`, `:headers` (map), `:receive_timeout` (ms a request may wait for its answer).
  Returns `{:error, {:invalid_url, url}}` or `{:error, {:missing_env, names}}` for a bad entry.
  """
  @impl true
  def start(opts) do
    with {:ok, url} <- validate_url(Keyword.get(opts, :url)),
         {:ok, headers} <- expand_headers(Keyword.get(opts, :headers) || %{}) do
      {:ok,
       %__MODULE__{
         url: url,
         headers: headers,
         receive_timeout: Keyword.get(opts, :receive_timeout, @default_receive_timeout)
       }}
    end
  end

  @impl true
  def send_message(%{mode: :legacy_connecting} = state, message),
    do: %{state | queue: state.queue ++ [message]}

  def send_message(state, message) do
    state =
      if initialize?(message) and state.mode == :streamable,
        do: %{state | init_message: message},
        else: state

    spawn_post(state, message)
  end

  @impl true
  def handle_info(state, {:mcp_http, :session, id}), do: {:ignore, %{state | session_id: id}}

  def handle_info(state, {:mcp_http, :message, message}) do
    {:messages, [message], remember_version(state, message)}
  end

  def handle_info(%{mode: :streamable} = state, {:mcp_http, :legacy, init_message}) do
    {:ignore, start_legacy(state, init_message)}
  end

  def handle_info(state, {:mcp_http, :sse_event, event, data})
      when state.mode in [:legacy_connecting, :legacy] do
    legacy_event(state, event, data)
  end

  def handle_info(state, {:mcp_http, :sse_closed, reason})
      when state.mode in [:legacy_connecting, :legacy] do
    {:closed, {:sse_closed, describe(reason)}, state}
  end

  def handle_info(state, {:DOWN, ref, :process, _pid, _reason})
      when is_map_key(state.tasks, ref) do
    {:ignore, %{state | tasks: Map.delete(state.tasks, ref), acks: Map.delete(state.acks, ref)}}
  end

  def handle_info(state, _other), do: {:ignore, state}

  @impl true
  def close(state) do
    # Ending the session is a courtesy: the answer, a `405` for a server that cannot, is not awaited.
    if state.mode == :streamable and is_binary(state.session_id) do
      ctx = context(state)

      spawn(fn ->
        req = Finch.build(:delete, state.url, request_headers(ctx, %{}, state.session_id))

        try do
          Finch.request(req, @pool, receive_timeout: 2_000)
        rescue
          _ -> :ok
        end
      end)
    end

    Enum.each(state.tasks, fn {_ref, pid} -> Process.exit(pid, :kill) end)
    :ok
  end

  # --- Start-up ---

  defp validate_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, url}

      _ ->
        {:error, {:invalid_url, url}}
    end
  end

  defp validate_url(url), do: {:error, {:invalid_url, url}}

  defp expand_headers(headers) when is_map(headers) do
    {pairs, missing, invalid} =
      Enum.reduce(headers, {[], [], []}, fn {name, value}, {pairs, missing, invalid} ->
        case expand_env(value) do
          {:ok, expanded} ->
            {[{String.downcase(to_string(name)), expanded} | pairs], missing, invalid}

          {:missing, names} ->
            {pairs, names ++ missing, invalid}

          :invalid ->
            {pairs, missing, [to_string(name) | invalid]}
        end
      end)

    cond do
      invalid != [] -> {:error, {:invalid_header, Enum.sort(invalid)}}
      missing != [] -> {:error, {:missing_env, missing |> Enum.uniq() |> Enum.sort()}}
      true -> {:ok, Enum.reverse(pairs)}
    end
  end

  defp expand_headers(_), do: {:error, {:invalid_header, ["headers must be an object"]}}

  @doc false
  # `${NAME}` becomes the value of the environment variable. Every unset name is reported.
  def expand_env(value) when is_number(value) or is_boolean(value), do: {:ok, to_string(value)}

  def expand_env(value) when is_binary(value) do
    names =
      @env_ref |> Regex.scan(value, capture: :all_but_first) |> List.flatten() |> Enum.uniq()

    case Enum.reject(names, &System.get_env/1) do
      [] -> {:ok, Regex.replace(@env_ref, value, fn _, name -> System.get_env(name) end)}
      missing -> {:missing, missing}
    end
  end

  def expand_env(_), do: :invalid

  # --- Owner side ---

  defp remember_version(state, %{"result" => %{"protocolVersion" => version}})
       when is_binary(version) do
    %{state | protocol_version: version}
  end

  defp remember_version(state, _message), do: state

  defp context(state) do
    %{
      url: if(state.mode == :legacy, do: state.endpoint, else: state.url),
      headers: state.headers,
      session_id: state.session_id,
      protocol_version: state.protocol_version,
      init_message: state.init_message,
      legacy?: state.mode == :legacy,
      receive_timeout: state.receive_timeout
    }
  end

  defp spawn_post(state, message) do
    owner = self()
    ctx = context(state)
    # Requests run side by side, but a request waits for the notifications sent before it:
    # `notifications/initialized` must reach the server before the first `tools/list`.
    earlier = Map.values(state.acks)

    {pid, ref} =
      spawn_monitor(fn ->
        await_exit(earlier)
        run_post(owner, ctx, message)
      end)

    acks = if request?(message), do: state.acks, else: Map.put(state.acks, ref, pid)
    %{state | tasks: Map.put(state.tasks, ref, pid), acks: acks}
  end

  defp await_exit(pids) do
    Enum.each(pids, fn pid ->
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, _, _} -> :ok
      after
        10_000 -> Process.demonitor(ref, [:flush])
      end
    end)
  end

  # The first POST failed the way an HTTP+SSE server does. Open the event stream and hold the
  # messages until the server names its endpoint.
  defp start_legacy(state, init_message) do
    Logger.debug("[MCP] #{state.url} does not accept POST on its URL; falling back to HTTP+SSE")
    owner = self()
    ctx = context(state)
    {pid, ref} = spawn_monitor(fn -> run_sse(owner, ctx) end)

    # The stream never ends by itself, so it must not outlive the client.
    spawn(fn ->
      owner_ref = Process.monitor(owner)
      stream_ref = Process.monitor(pid)

      receive do
        {:DOWN, ^owner_ref, _, _, _} -> Process.exit(pid, :kill)
        {:DOWN, ^stream_ref, _, _, _} -> :ok
      end
    end)

    %{
      state
      | mode: :legacy_connecting,
        queue: [init_message | state.queue],
        sse: pid,
        tasks: Map.put(state.tasks, ref, pid)
    }
  end

  defp legacy_event(%{mode: :legacy_connecting} = state, "endpoint", data) do
    endpoint = state.url |> URI.merge(String.trim(data)) |> URI.to_string()

    if same_origin?(state.url, endpoint) do
      ready = %{state | mode: :legacy, endpoint: endpoint, queue: []}
      {:ignore, Enum.reduce(state.queue, ready, &spawn_post(&2, &1))}
    else
      {:closed, {:bad_endpoint, endpoint}, state}
    end
  end

  defp legacy_event(state, "message", data) do
    case decode_messages(data) do
      {:ok, messages} ->
        {:messages, messages, Enum.reduce(messages, state, &remember_version(&2, &1))}

      :error ->
        {:ignore, state}
    end
  end

  defp legacy_event(state, _event, _data), do: {:ignore, state}

  defp same_origin?(a, b) do
    {ua, ub} = {URI.parse(a), URI.parse(b)}
    {ua.scheme, ua.host, ua.port} == {ub.scheme, ub.host, ub.port}
  end

  # --- Request side (one process per request) ---

  defp run_post(owner, ctx, message) do
    case safely(fn -> post(owner, ctx, message) end) do
      :ok -> :ok
      {:error, reason} -> report_failure(owner, message, reason)
    end
  end

  defp safely(fun) do
    fun.()
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp post(owner, ctx, message) do
    case exchange(owner, ctx, message, ctx.session_id) do
      # HTTP+SSE: the answer comes on the event stream, not in this response.
      {:ok, %{status: status}} when status in 200..299 and ctx.legacy? ->
        :ok

      {:ok, %{status: status} = response} when status in 200..299 ->
        check_answered(message, response)

      # The server dropped the session. Start a new one and repeat the request once.
      {:ok, %{status: 404}} when is_binary(ctx.session_id) and not ctx.legacy? ->
        if initialize?(message),
          do: {:error, {:http_status, 404, ""}},
          else: reinitialize_and_retry(owner, ctx, message)

      {:ok, %{status: status}} when status in [404, 405] and not ctx.legacy? ->
        if initialize?(message) and is_nil(ctx.session_id) do
          send(owner, {:mcp_http, :legacy, message})
          :ok
        else
          {:error, {:http_status, status, ""}}
        end

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_status, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reinitialize_and_retry(owner, ctx, message) do
    with %{} = init <- ctx.init_message,
         {:ok, %{status: status, headers: headers}} when status in 200..299 <-
           exchange(
             :silent,
             ctx,
             Map.put(init, "id", "reinit-#{System.unique_integer([:positive])}"),
             nil
           ),
         session when is_binary(session) <- header(headers, "mcp-session-id"),
         {:ok, %{status: ack}} when ack in 200..299 <-
           exchange(
             :silent,
             ctx,
             %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
             session
           ) do
      send(owner, {:mcp_http, :session, session})

      case exchange(owner, ctx, message, session) do
        {:ok, %{status: status} = response} when status in 200..299 ->
          check_answered(message, response)

        {:ok, %{status: status, body: body}} ->
          {:error, {:http_status, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    else
      _ -> {:error, :session_expired}
    end
  end

  # A request needs an answer in its own response. Anything else would hang the caller until its timeout.
  defp check_answered(message, %{status: status, ids: ids}) do
    if request?(message) and message["id"] not in ids,
      do: {:error, {:no_response, status}},
      else: :ok
  end

  # Sends one POST. Messages go to `sink` (the owner, or `:silent`) while the body is still arriving.
  defp exchange(sink, ctx, message, session_id) do
    request =
      Finch.build(
        :post,
        ctx.url,
        request_headers(ctx, message, session_id),
        Jason.encode!(message)
      )

    acc = %{
      status: nil,
      headers: [],
      body: [],
      size: 0,
      sse: nil,
      ids: [],
      sink: sink,
      session_id: session_id
    }

    case Finch.stream(request, @pool, acc, &on_chunk/2, receive_timeout: ctx.receive_timeout) do
      {:ok, acc} -> {:ok, finish(acc)}
      {:error, exception, _acc} -> {:error, exception}
    end
  end

  defp on_chunk({:status, status}, acc), do: %{acc | status: status}

  defp on_chunk({:headers, headers}, acc) do
    headers = Enum.map(headers, fn {k, v} -> {String.downcase(k), v} end)

    sse? =
      acc.status in 200..299 and
        String.starts_with?(header(headers, "content-type") || "", "text/event-stream")

    # Before the first message, so the owner holds the session when it answers the handshake.
    with true <- acc.status in 200..299,
         session when is_binary(session) and session != acc.session_id <-
           header(headers, "mcp-session-id"),
         pid when is_pid(pid) <- acc.sink do
      send(pid, {:mcp_http, :session, session})
    end

    %{acc | headers: headers, sse: if(sse?, do: "")}
  end

  defp on_chunk({:data, data}, %{sse: buffer} = acc) when is_binary(buffer) do
    {events, rest} = split_events(buffer <> data)
    deliver_events(%{acc | sse: rest}, events)
  end

  defp on_chunk({:data, data}, acc) do
    if acc.size + byte_size(data) <= @max_body,
      do: %{acc | body: [acc.body, data], size: acc.size + byte_size(data)},
      else: acc
  end

  defp on_chunk(_other, acc), do: acc

  defp finish(%{sse: buffer} = acc) when is_binary(buffer) do
    # A stream that closes without the blank line after its last event still delivered it.
    {events, _rest} = split_events(buffer <> "\n\n")
    acc = deliver_events(%{acc | sse: ""}, events)
    %{status: acc.status, headers: acc.headers, body: "", ids: acc.ids}
  end

  defp finish(acc) do
    body = IO.iodata_to_binary(acc.body)

    ids =
      if acc.status in 200..299 and String.trim(body) != "" do
        case decode_messages(body) do
          {:ok, messages} -> deliver(acc.sink, messages)
          :error -> []
        end
      else
        []
      end

    %{status: acc.status, headers: acc.headers, body: String.slice(body, 0, 500), ids: ids}
  end

  defp deliver_events(acc, events) do
    ids =
      Enum.flat_map(events, fn
        {"message", data} ->
          case decode_messages(data) do
            {:ok, messages} -> deliver(acc.sink, messages)
            :error -> []
          end

        _ ->
          []
      end)

    %{acc | ids: acc.ids ++ ids}
  end

  # Returns the ids of the responses among the messages.
  defp deliver(sink, messages) do
    if is_pid(sink), do: Enum.each(messages, &send(sink, {:mcp_http, :message, &1}))

    for %{"id" => id} = m <- messages,
        Map.has_key?(m, "result") or Map.has_key?(m, "error"),
        do: id
  end

  defp decode_messages(data) do
    case Jason.decode(data) do
      {:ok, %{} = message} -> {:ok, [message]}
      {:ok, list} when is_list(list) -> {:ok, Enum.filter(list, &is_map/1)}
      _ -> :error
    end
  end

  defp report_failure(owner, message, reason) do
    if request?(message) do
      error = %{
        "jsonrpc" => "2.0",
        "id" => message["id"],
        "error" => %{"code" => -32000, "message" => describe(reason)}
      }

      send(owner, {:mcp_http, :message, error})
    else
      Logger.debug("[MCP] #{message["method"] || "response"} not delivered: #{describe(reason)}")
    end
  end

  defp request?(message), do: is_binary(message["method"]) and Map.has_key?(message, "id")
  defp initialize?(message), do: message["method"] == "initialize"

  defp request_headers(ctx, message, session_id) do
    defaults = [
      {"content-type", "application/json"},
      {"accept", "application/json, text/event-stream"}
    ]

    version =
      if ctx.protocol_version && not initialize?(message),
        do: [{"mcp-protocol-version", ctx.protocol_version}],
        else: []

    session = if session_id, do: [{"mcp-session-id", session_id}], else: []

    # The configured headers go last, so a user can override a default.
    Map.to_list(Map.merge(Map.new(defaults ++ version ++ session), Map.new(ctx.headers)))
  end

  defp header(headers, name) do
    Enum.find_value(headers, fn {k, v} -> if String.downcase(k) == name, do: v end)
  end

  # --- Legacy HTTP+SSE event stream ---

  defp run_sse(owner, ctx) do
    request =
      Finch.build(
        :get,
        ctx.url,
        Map.to_list(Map.merge(%{"accept" => "text/event-stream"}, Map.new(ctx.headers)))
      )

    acc = %{status: nil, buffer: ""}

    fun = fn
      {:status, status}, acc ->
        %{acc | status: status}

      {:data, data}, %{status: 200} = acc ->
        {events, rest} = split_events(acc.buffer <> data)

        Enum.each(events, fn {event, payload} ->
          send(owner, {:mcp_http, :sse_event, event, payload})
        end)

        %{acc | buffer: rest}

      _other, acc ->
        acc
    end

    reason =
      case safely(fn -> Finch.stream(request, @pool, acc, fun, receive_timeout: :infinity) end) do
        {:ok, %{status: 200}} -> :eof
        {:ok, %{status: status}} -> {:http_status, status, ""}
        {:error, exception, _acc} -> exception
        {:error, other} -> other
      end

    send(owner, {:mcp_http, :sse_closed, reason})
  end

  # --- SSE parsing ---

  # Splits a buffer into complete `{event, data}` pairs and the unfinished rest. The default event
  # type is "message". A block without a data line (a comment, a keep-alive) yields nothing.
  defp split_events(buffer) do
    {complete, [rest]} =
      buffer |> String.replace("\r\n", "\n") |> String.split("\n\n") |> Enum.split(-1)

    {Enum.flat_map(complete, &parse_event/1), rest}
  end

  defp parse_event(block) do
    {event, data} =
      block
      |> String.split("\n")
      |> Enum.reduce({"message", []}, fn
        "event:" <> value, {_event, data} -> {strip_space(value), data}
        "data:" <> value, {event, data} -> {event, [strip_space(value) | data]}
        _other, acc -> acc
      end)

    if data == [], do: [], else: [{event, data |> Enum.reverse() |> Enum.join("\n")}]
  end

  defp strip_space(" " <> rest), do: rest
  defp strip_space(value), do: value

  defp describe({:http_status, status, body}) do
    "HTTP #{status}" <>
      if(String.trim(to_string(body)) == "",
        do: "",
        else: ": " <> String.slice(String.trim(to_string(body)), 0, 200)
      )
  end

  defp describe({:no_response, status}),
    do: "the server sent no response to the request (HTTP #{status})"

  defp describe(:session_expired),
    do: "the server dropped the session and a new one could not be started"

  defp describe(%{__exception__: true} = exception), do: Exception.message(exception)
  defp describe(other), do: inspect(other)
end
