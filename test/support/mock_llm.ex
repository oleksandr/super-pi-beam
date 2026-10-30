defmodule SuperPi.TestSupport.MockLLM do
  @moduledoc """
  A local HTTP server that plays the part of a model API in tests. It answers each request with the
  next scripted response and reports every request to the test process, so a test can check what was
  sent.

      {url, _} = MockLLM.start([{200, MockLLM.sse(events)}])
      # ... call the provider with base_url: url ...
      assert_receive {:llm_request, %{path: "/v1/messages", headers: headers, body: body}}
  """

  defmodule Plug do
    @moduledoc false
    @behaviour Elixir.Plug

    def init(opts), do: opts

    def call(conn, %{agent: agent, test: test}) do
      {:ok, raw, conn} = Elixir.Plug.Conn.read_body(conn)

      body =
        case Jason.decode(raw) do
          {:ok, b} -> b
          _ -> raw
        end

      send(
        test,
        {:llm_request, %{path: conn.request_path, headers: Map.new(conn.req_headers), body: body}}
      )

      response =
        Agent.get_and_update(agent, fn
          [next | rest] -> {next, rest}
          [] -> {{500, [], "no scripted response left"}, []}
        end)

      {status, headers, payload} = normalize(response)

      conn =
        Enum.reduce(headers, conn, fn {k, v}, c -> Elixir.Plug.Conn.put_resp_header(c, k, v) end)

      case payload do
        chunks when is_list(chunks) ->
          conn =
            Elixir.Plug.Conn.put_resp_content_type(conn, "text/event-stream")
            |> Elixir.Plug.Conn.send_chunked(status)

          Enum.reduce(chunks, conn, fn chunk, c ->
            {:ok, c} = Elixir.Plug.Conn.chunk(c, chunk)
            c
          end)

        text when is_binary(text) ->
          Elixir.Plug.Conn.send_resp(conn, status, text)
      end
    end

    defp normalize({status, payload}), do: {status, [], payload}
    defp normalize({status, headers, payload}), do: {status, headers, payload}
  end

  @doc "Starts the server. `script` is a list of `{status, payload}` or `{status, headers, payload}`; a payload is a string or a list of chunks. Returns `{base_url, agent}`."
  def start(script) do
    {:ok, agent} = Agent.start_link(fn -> script end)
    test = self()

    {:ok, server} =
      Bandit.start_link(
        plug: {Plug, %{agent: agent, test: test}},
        port: 0,
        ip: {127, 0, 0, 1},
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    {"http://127.0.0.1:#{port}", agent}
  end

  @doc "Encodes events as SSE and splits the bytes into small chunks, so chunk boundaries fall inside lines."
  def sse(events, chunk_size \\ 37) do
    body =
      Enum.map_join(events, "", fn
        {name, data} when is_binary(name) -> "event: #{name}\ndata: #{Jason.encode!(data)}\n\n"
        :done -> "data: [DONE]\n\n"
        data -> "data: #{Jason.encode!(data)}\n\n"
      end)

    split(body, chunk_size)
  end

  defp split(bin, n) when byte_size(bin) <= n, do: [bin]

  defp split(bin, n),
    do: [binary_part(bin, 0, n) | split(binary_part(bin, n, byte_size(bin) - n), n)]
end
