defmodule SuperPi.Web.Fetch do
  @moduledoc """
  The HTTP side of `web_fetch`: one GET with the request-forgery policy, a decoded-byte cap and
  a deadline. It returns bytes and metadata. `SuperPi.Web.Extract` turns them into text.

  ## Guarantees

  - **Policy on every hop.** `SuperPi.Web.Policy.check_url/2` runs before the first request and
    again for each redirect. Redirects are followed here, never by Req (`redirect: false`), at
    most `Policy.max_redirects/0`.
  - **The cap counts decoded bytes.** The response streams with Req's decoding off
    (`raw: true`), and this module inflates `gzip` and `deflate` itself, a bounded step at a
    time (`:zlib.safeInflate/2`). It stops as soon as the decoded size passes `max_bytes`, so a
    1 MB gzip bomb costs `max_bytes` of memory, not gigabytes. A `Content-Length` check would
    bound nothing here. `max_bytes` defaults to 2 MiB and is clamped to 8 MiB. A body that passes
    the cap is cut there and flagged `body_truncated`.
  - **Isolation.** The whole chain (DNS, requests, inflate) runs under
    `SuperPi.Env.SandboxRunner.run_isolated/2`: a wall-clock deadline and a heap kill. The
    machine's own tool task sets no heap limit, so this call must set it.
  - **Own connection pool.** Requests go through the `SuperPi.WebFinch` pool, not the provider
    pool, so agent-controlled egress shares no pool or failure budget with LLM traffic.
  - **No caller headers.** The request headers are fixed here. There is no way to add one.
  - **Early content-type refusal.** Unless `accept_binary: true`, a PDF or other binary
    response is refused from its headers, before the body is read.

  Only `Accept-Encoding: gzip, deflate` is offered, so a server has no reason to answer with
  `br` or `zstd`. If it does, the fetch fails with an `:encoding` error.

  ## Options

  `:max_bytes`, `:timeout_ms` (whole chain, default 20 s), `:accept_binary`, `:resolver`,
  `:pin_ip` (see `SuperPi.Web.Policy`, off by default and unverified), `:finch` (pool name),
  `:req_options` (merged into every request, for operators and tests: a `:plug` stub keeps a
  test offline) and `:unsafe_allow_local` (test only).
  """

  alias SuperPi.Env.SandboxRunner
  alias SuperPi.Web.{Extract, Policy}

  @default_max_bytes 2 * 1024 * 1024
  @hard_max_bytes 8 * 1024 * 1024
  @default_timeout_ms 20_000
  # A 4xx or 5xx body only explains the error. It never needs more than this.
  @error_body_bytes 16 * 1024
  @redirect_statuses [301, 302, 303, 307, 308]
  @user_agent "super-pi-web/1 (+https://github.com/super-pi)"

  @type response :: %{
          final_url: String.t(),
          status: non_neg_integer(),
          content_type: String.t() | nil,
          body: binary(),
          body_truncated: boolean(),
          bytes: non_neg_integer(),
          chain: [map()],
          ip: String.t() | nil,
          duration_ms: non_neg_integer()
        }

  @type error ::
          {:refused, String.t()}
          | {:dns, term()}
          | {:content_type, String.t()}
          | {:encoding, String.t()}
          | {:too_many_redirects, pos_integer()}
          | {:timeout, pos_integer()}
          | {:transport, String.t()}
          | {:crashed, String.t()}

  @doc "Default and hard limits, in bytes."
  @spec limits() :: %{default: pos_integer(), hard: pos_integer()}
  def limits, do: %{default: @default_max_bytes, hard: @hard_max_bytes}

  @doc """
  Fetches a URL. See the moduledoc for options and guarantees.
  """
  @spec get(term(), keyword()) :: {:ok, response()} | {:error, error()}
  def get(url, opts \\ []) do
    max_bytes = opts |> Keyword.get(:max_bytes, @default_max_bytes) |> clamp(@hard_max_bytes)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    opts = Keyword.put(opts, :max_bytes, max_bytes)
    started = System.monotonic_time(:millisecond)

    case SandboxRunner.run_isolated(fn -> follow(url, opts, [], 0) end, timeout_ms: timeout_ms) do
      {:ok, {:ok, response}} ->
        {:ok, Map.put(response, :duration_ms, System.monotonic_time(:millisecond) - started)}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, %{type: "tool_timeout"}} ->
        {:error, {:timeout, timeout_ms}}

      {:error, %{reason: reason}} ->
        {:error, {:crashed, to_string(reason)}}
    end
  end

  defp clamp(value, hard) when is_integer(value) and value > 0, do: min(value, hard)
  defp clamp(_value, _hard), do: @default_max_bytes

  # --- Redirect loop -------------------------------------------------------------------------

  defp follow(url, opts, chain, redirects) do
    policy_opts = Keyword.take(opts, [:resolver, :unsafe_allow_local])

    with {:ok, target} <- Policy.check_url(url, policy_opts),
         {:ok, resp} <- request(target, opts) do
      hop = %{"url" => URI.to_string(target.uri), "status" => resp.status, "ip" => ip_text(target.ips)}
      chain = chain ++ [hop]

      case redirect_location(resp) do
        nil ->
          {:ok, finish(target, resp, chain)}

        location ->
          if redirects >= Policy.max_redirects() do
            {:error, {:too_many_redirects, Policy.max_redirects()}}
          else
            with {:ok, next} <- Policy.redirect_url(target.uri, location), do: follow(next, opts, chain, redirects + 1)
          end
      end
    end
  end

  defp redirect_location(%{status: status, location: location}) when status in @redirect_statuses and is_binary(location) and location != "",
    do: location

  defp redirect_location(_resp), do: nil

  defp finish(target, resp, chain) do
    %{
      final_url: URI.to_string(target.uri),
      status: resp.status,
      content_type: resp.content_type,
      body: resp.body,
      body_truncated: resp.truncated,
      bytes: byte_size(resp.body),
      chain: chain,
      ip: ip_text(target.ips)
    }
  end

  defp ip_text([ip | _]), do: Policy.ip_to_string(ip)
  defp ip_text(_), do: nil

  # --- One request ---------------------------------------------------------------------------

  defp request(target, opts) do
    # Req refuses `:finch` together with `:connect_options`, so the pinned path (which needs a
    # per-request `hostname`) cannot use the dedicated pool. It gets a pool Req starts for those
    # connect options. One more reason the flag is off by default.
    {uri, transport} =
      if Keyword.get(opts, :pin_ip, false) == true do
        {pinned, hostname} = Policy.pin(target)
        {pinned, [connect_options: [timeout: 10_000, hostname: hostname]]}
      else
        {target.uri, [finch: [name: Keyword.get(opts, :finch, SuperPi.WebFinch)]]}
      end

    max_bytes = Keyword.fetch!(opts, :max_bytes)
    accept_binary? = Keyword.get(opts, :accept_binary, false) == true

    req_opts =
      [
        method: :get,
        url: uri,
        headers: [
          {"user-agent", @user_agent},
          {"accept", "text/html,application/xhtml+xml,application/json,text/plain;q=0.9,*/*;q=0.5"},
          {"accept-encoding", "gzip, deflate"}
        ],
        redirect: false,
        retry: false,
        raw: true,
        decode_body: false,
        compressed: false,
        receive_timeout: 15_000,
        into: fn {:data, chunk}, {req, resp} -> stream_chunk(chunk, req, resp, max_bytes, accept_binary?) end
      ] ++ transport ++ Keyword.get(opts, :req_options, [])

    try do
      case Req.request(req_opts) do
        {:ok, resp} -> read_result(resp)
        {:error, exception} -> {:error, {:transport, Exception.message(exception)}}
      end
    after
      close_inflater()
    end
  rescue
    e -> {:error, {:transport, Exception.message(e)}}
  end

  # The state lives in the response's private map: the `into` function is called once per chunk.
  defp stream_chunk(chunk, req, resp, max_bytes, accept_binary?) do
    state = Req.Response.get_private(resp, :web_state) || init_state(resp, max_bytes, accept_binary?)

    {action, state} =
      case state do
        %{stop: nil} -> ingest(state, chunk)
        %{stop: _} -> {:halt, state}
      end

    resp = Req.Response.put_private(resp, :web_state, state)
    {action, {req, resp}}
  end

  defp init_state(resp, max_bytes, accept_binary?) do
    status = resp.status
    type = header(resp, "content-type")
    encoding = resp |> header("content-encoding") |> to_string() |> String.downcase() |> String.trim()
    cap = if status in 200..299, do: max_bytes, else: min(max_bytes, @error_body_bytes)

    stop =
      cond do
        status in @redirect_statuses and header(resp, "location") not in [nil, ""] -> :redirect
        status in 200..299 and not accept_binary? and Extract.kind(type, nil) in [:pdf, :binary] -> {:content_type, type || "unknown"}
        encoding not in ["", "identity", "gzip", "x-gzip", "deflate"] -> {:encoding, "Unsupported Content-Encoding `#{encoding}`."}
        true -> nil
      end

    %{
      stop: stop,
      cap: cap,
      count: 0,
      chunks: [],
      truncated: false,
      inflate?: encoding in ["gzip", "x-gzip", "deflate"],
      zlib: nil
    }
  end

  defp ingest(%{inflate?: false} = state, chunk), do: take(state, chunk)

  defp ingest(%{inflate?: true} = state, chunk) do
    z = state.zlib || open_inflater()
    state = %{state | zlib: z}
    inflate(state, z, chunk)
  rescue
    e in ErlangError -> {:halt, %{state | stop: {:encoding, "Cannot decode the response body: #{inspect(e.original)}."}}}
  end

  # One `safeInflate` call yields at most 16 KiB, so the loop checks the cap after
  # every step and a bomb never materializes.
  defp inflate(state, z, data) do
    case :zlib.safeInflate(z, data) do
      {:continue, out} ->
        case take(state, out) do
          {:cont, state} -> inflate(state, z, [])
          halted -> halted
        end

      {:finished, out} ->
        # Anything after the end of the compressed stream is ignored.
        take(%{state | stop: nil}, out) |> finished()

      {:need_dictionary, _, _} ->
        {:halt, %{state | stop: {:encoding, "The response needs a zlib dictionary."}}}
    end
  end

  defp finished({:cont, state}), do: {:halt, %{state | stop: :done}}
  defp finished(halted), do: halted

  # Adds decoded bytes. Past the cap, keeps what fits and stops reading.
  defp take(state, data) do
    size = IO.iodata_length(data)
    room = state.cap - state.count

    cond do
      size <= room ->
        {:cont, %{state | chunks: [data | state.chunks], count: state.count + size}}

      room > 0 ->
        kept = binary_part(IO.iodata_to_binary(data), 0, room)
        {:halt, %{state | chunks: [kept | state.chunks], count: state.cap, truncated: true, stop: :cap}}

      true ->
        {:halt, %{state | truncated: true, stop: :cap}}
    end
  end

  defp read_result(resp) do
    state = Req.Response.get_private(resp, :web_state)

    case state do
      %{stop: {:content_type, _} = reason} -> {:error, reason}
      %{stop: {:encoding, _} = reason} -> {:error, reason}
      _ -> {:ok, build(resp, state)}
    end
  end

  defp build(resp, nil) do
    %{status: resp.status, content_type: header(resp, "content-type"), location: header(resp, "location"), body: "", truncated: false}
  end

  defp build(resp, state) do
    body = state.chunks |> Enum.reverse() |> IO.iodata_to_binary()
    %{status: resp.status, content_type: header(resp, "content-type"), location: header(resp, "location"), body: body, truncated: state.truncated}
  end

  defp header(resp, name) do
    case Req.Response.get_header(resp, name) do
      [value | _] -> value
      _ -> nil
    end
  end

  # The inflater is a port owned by the isolated task. It is closed after each request, and the task's
  # exit closes any that remain.
  defp open_inflater do
    z = :zlib.open()
    # Window 47: gzip or zlib framing, detected from the header.
    :zlib.inflateInit(z, 47)
    Process.put({__MODULE__, :zlib}, z)
    z
  end

  defp close_inflater do
    case Process.delete({__MODULE__, :zlib}) do
      nil -> :ok
      z -> :zlib.close(z)
    end
  end
end
