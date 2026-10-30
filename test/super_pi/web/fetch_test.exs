defmodule SuperPi.Web.FetchTest do
  @moduledoc """
  Offline: requests go to a `plug:` function (Req's test adapter) or to a Bandit server on
  127.0.0.1 with the policy bypass `unsafe_allow_local`, which only tests set.
  """
  use ExUnit.Case, async: true

  alias SuperPi.Web.Fetch

  @public {93, 184, 216, 34}
  @kib 1024
  @mib 1024 * 1024

  defmodule FunPlug do
    @moduledoc false
    def init(fun), do: fun
    def call(conn, fun), do: fun.(conn)
  end

  # A host-to-address map. The test never reaches DNS.
  defp resolver(map \\ %{}), do: fn host -> {:ok, [Map.get(map, host, @public)]} end

  defp opts(plug, extra \\ []), do: [resolver: resolver(), req_options: [plug: plug]] ++ extra

  defp send_gzip(conn, data, type \\ "text/html") do
    conn
    |> Plug.Conn.put_resp_header("content-type", type)
    |> Plug.Conn.put_resp_header("content-encoding", "gzip")
    |> Plug.Conn.send_resp(200, :zlib.gzip(data))
  end

  describe "a plain fetch" do
    test "returns the body, final URL, chain and address" do
      plug = fn conn ->
        conn |> Plug.Conn.put_resp_content_type("text/plain") |> Plug.Conn.send_resp(200, "hello")
      end

      assert {:ok, r} = Fetch.get("https://example.com/a", opts(plug))
      assert r.status == 200
      assert r.body == "hello"
      assert r.bytes == 5
      refute r.body_truncated
      assert r.final_url == "https://example.com/a"
      assert r.content_type =~ "text/plain"
      assert r.ip == "93.184.216.34"
      assert [%{"url" => "https://example.com/a", "status" => 200, "ip" => "93.184.216.34"}] = r.chain
      assert is_integer(r.duration_ms)
    end

    test "inflates gzip and deflate bodies" do
      gz = fn conn -> send_gzip(conn, "<p>zipped</p>") end
      assert {:ok, %{body: "<p>zipped</p>"}} = Fetch.get("https://example.com/", opts(gz))

      deflate = fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "text/plain")
        |> Plug.Conn.put_resp_header("content-encoding", "deflate")
        |> Plug.Conn.send_resp(200, :zlib.compress("deflated"))
      end

      assert {:ok, %{body: "deflated"}} = Fetch.get("https://example.com/", opts(deflate))
    end

    test "sends fixed headers and no caller headers" do
      parent = self()

      plug = fn conn ->
        send(parent, {:headers, conn.req_headers})
        Plug.Conn.send_resp(conn, 200, "ok")
      end

      assert {:ok, _} = Fetch.get("https://example.com/", opts(plug, headers: [{"authorization", "Bearer x"}]))
      assert_receive {:headers, headers}
      keys = Enum.map(headers, &elem(&1, 0))
      refute "authorization" in keys
      assert "user-agent" in keys
      assert {"accept-encoding", "gzip, deflate"} in headers
    end

    test "a 404 is returned as a status, not an error" do
      plug = fn conn -> Plug.Conn.send_resp(conn, 404, "nope") end
      assert {:ok, %{status: 404, body: "nope"}} = Fetch.get("https://example.com/missing", opts(plug))
    end

    test "an error body is read only up to a small cap" do
      plug = fn conn -> Plug.Conn.send_resp(conn, 500, String.duplicate("x", 200 * @kib)) end
      assert {:ok, %{status: 500, body: body, body_truncated: true}} = Fetch.get("https://example.com/", opts(plug))
      assert byte_size(body) == 16 * @kib
    end
  end

  describe "the decoded-byte cap" do
    test "a gzip bomb stops at max_bytes (200 KB compressed to 200 MB would not)" do
      # 50 MB of zeros compresses to about 50 KB.
      bomb = :zlib.gzip(:binary.copy(<<0>>, 50 * @mib))
      assert byte_size(bomb) < 100 * @kib

      plug = fn conn ->
        conn |> Plug.Conn.put_resp_header("content-type", "text/plain") |> Plug.Conn.put_resp_header("content-encoding", "gzip") |> Plug.Conn.send_resp(200, bomb)
      end

      assert {:ok, r} = Fetch.get("https://example.com/", opts(plug, max_bytes: 64 * @kib))
      assert byte_size(r.body) == 64 * @kib
      assert r.body_truncated
      assert r.bytes == 64 * @kib
    end

    test "the default cap is 2 MiB" do
      bomb = :zlib.gzip(:binary.copy("a", 20 * @mib))
      plug = fn conn -> conn |> Plug.Conn.put_resp_header("content-type", "text/plain") |> Plug.Conn.put_resp_header("content-encoding", "gzip") |> Plug.Conn.send_resp(200, bomb) end

      assert {:ok, r} = Fetch.get("https://example.com/", opts(plug))
      assert byte_size(r.body) == 2 * @mib
      assert r.body_truncated
    end

    test "a requested cap above the hard cap is clamped to 8 MiB" do
      bomb = :zlib.gzip(:binary.copy("a", 20 * @mib))
      plug = fn conn -> conn |> Plug.Conn.put_resp_header("content-type", "text/plain") |> Plug.Conn.put_resp_header("content-encoding", "gzip") |> Plug.Conn.send_resp(200, bomb) end

      assert {:ok, r} = Fetch.get("https://example.com/", opts(plug, max_bytes: 1024 * @mib))
      assert byte_size(r.body) == 8 * @mib
      assert Fetch.limits().hard == 8 * @mib
    end

    test "an uncompressed body is cut at the cap too" do
      plug = fn conn -> conn |> Plug.Conn.put_resp_content_type("text/plain") |> Plug.Conn.send_resp(200, String.duplicate("y", 300 * @kib)) end
      assert {:ok, r} = Fetch.get("https://example.com/", opts(plug, max_bytes: 100 * @kib))
      assert byte_size(r.body) == 100 * @kib
      assert r.body_truncated
    end

    test "a body under the cap is not flagged" do
      plug = fn conn -> conn |> Plug.Conn.put_resp_content_type("text/plain") |> Plug.Conn.send_resp(200, String.duplicate("y", 10)) end
      assert {:ok, %{body_truncated: false}} = Fetch.get("https://example.com/", opts(plug, max_bytes: 100))
    end

    test "a broken gzip stream is an encoding error, not a crash" do
      plug = fn conn ->
        conn |> Plug.Conn.put_resp_header("content-type", "text/plain") |> Plug.Conn.put_resp_header("content-encoding", "gzip") |> Plug.Conn.send_resp(200, "this is not gzip")
      end

      assert {:error, {:encoding, _}} = Fetch.get("https://example.com/", opts(plug))
    end

    test "an unsupported content encoding is refused" do
      plug = fn conn ->
        conn |> Plug.Conn.put_resp_header("content-type", "text/plain") |> Plug.Conn.put_resp_header("content-encoding", "br") |> Plug.Conn.send_resp(200, "x")
      end

      assert {:error, {:encoding, msg}} = Fetch.get("https://example.com/", opts(plug))
      assert msg =~ "br"
    end
  end

  describe "content types" do
    test "a PDF or binary type is refused from the headers unless accept_binary" do
      plug = fn conn -> conn |> Plug.Conn.put_resp_header("content-type", "application/pdf") |> Plug.Conn.send_resp(200, "%PDF-1.7 data") end
      assert {:error, {:content_type, "application/pdf"}} = Fetch.get("https://example.com/a.pdf", opts(plug))
      assert {:ok, %{body: "%PDF-1.7 data"}} = Fetch.get("https://example.com/a.pdf", opts(plug, accept_binary: true))

      png = fn conn -> conn |> Plug.Conn.put_resp_header("content-type", "image/png") |> Plug.Conn.send_resp(200, <<137, 80, 78, 71>>) end
      assert {:error, {:content_type, "image/png"}} = Fetch.get("https://example.com/a.png", opts(png))
    end
  end

  describe "redirects" do
    defp redirecting(table) do
      fn conn ->
        case Map.get(table, {conn.host, conn.request_path}) do
          {:redirect, location} -> conn |> Plug.Conn.put_resp_header("location", location) |> Plug.Conn.send_resp(302, "")
          {:ok, body} -> conn |> Plug.Conn.put_resp_content_type("text/plain") |> Plug.Conn.send_resp(200, body)
          nil -> Plug.Conn.send_resp(conn, 404, "")
        end
      end
    end

    test "follows relative and absolute redirects and records the chain" do
      plug = redirecting(%{{"a.example", "/"} => {:redirect, "/next"}, {"a.example", "/next"} => {:redirect, "https://b.example/final"}, {"b.example", "/final"} => {:ok, "done"}})
      assert {:ok, r} = Fetch.get("https://a.example/", opts(plug))
      assert r.body == "done"
      assert r.final_url == "https://b.example/final"
      assert Enum.map(r.chain, & &1["status"]) == [302, 302, 200]
    end

    test "a public host that redirects to 127.0.0.1 is refused" do
      plug = redirecting(%{{"public.example", "/"} => {:redirect, "http://127.0.0.1/admin"}, {"127.0.0.1", "/admin"} => {:ok, "SECRET"}})
      assert {:error, {:refused, msg}} = Fetch.get("https://public.example/", opts(plug))
      assert msg =~ "reserved"
    end

    test "a redirect to the cloud metadata address is refused" do
      plug = redirecting(%{{"public.example", "/"} => {:redirect, "http://169.254.169.254/latest/meta-data/"}})
      assert {:error, {:refused, _}} = Fetch.get("https://public.example/", opts(plug))
    end

    test "a redirect to a name that resolves to a private address is refused" do
      plug = redirecting(%{{"public.example", "/"} => {:redirect, "https://rebind.example/"}, {"rebind.example", "/"} => {:ok, "SECRET"}})
      r = resolver(%{"rebind.example" => {10, 0, 0, 7}})
      assert {:error, {:refused, msg}} = Fetch.get("https://public.example/", resolver: r, req_options: [plug: plug])
      assert msg =~ "10.0.0.7"
    end

    test "a redirect to localhost, a bad scheme or a bad port is refused" do
      for location <- ["http://localhost/", "ftp://public.example/x", "http://public.example:8080/", "http://user:pw@public.example/"] do
        plug = redirecting(%{{"public.example", "/"} => {:redirect, location}})
        assert {:error, {:refused, _}} = Fetch.get("https://public.example/", opts(plug)), location
      end
    end

    test "stops after five redirects" do
      plug = fn conn ->
        n = conn.request_path |> String.trim_leading("/") |> then(&if(&1 == "", do: 0, else: String.to_integer(&1)))
        conn |> Plug.Conn.put_resp_header("location", "/#{n + 1}") |> Plug.Conn.send_resp(302, "")
      end

      assert {:error, {:too_many_redirects, 5}} = Fetch.get("https://loop.example/", opts(plug))
    end

    test "five redirects are allowed" do
      plug = fn conn ->
        n = conn.request_path |> String.trim_leading("/") |> then(&if(&1 == "", do: 0, else: String.to_integer(&1)))

        if n < 5 do
          conn |> Plug.Conn.put_resp_header("location", "/#{n + 1}") |> Plug.Conn.send_resp(302, "")
        else
          conn |> Plug.Conn.put_resp_content_type("text/plain") |> Plug.Conn.send_resp(200, "end")
        end
      end

      assert {:ok, %{body: "end", chain: chain}} = Fetch.get("https://loop.example/", opts(plug))
      assert length(chain) == 6
    end
  end

  describe "policy and failures" do
    test "a refused URL makes no request" do
      plug = fn _conn -> flunk("a request was made") end
      assert {:error, {:refused, _}} = Fetch.get("http://127.0.0.1/", opts(plug))
      assert {:error, {:refused, _}} = Fetch.get("http://example.com:8080/", opts(plug))
      assert {:error, {:refused, _}} = Fetch.get("file:///etc/passwd", opts(plug))
    end

    test "a failed lookup is a DNS error" do
      assert {:error, {:dns, :nxdomain}} = Fetch.get("https://gone.example/", resolver: fn _ -> {:error, :nxdomain} end)
    end

    test "a transport error is reported, not raised" do
      plug = fn conn -> Req.Test.transport_error(conn, :econnrefused) end
      assert {:error, {:transport, _}} = Fetch.get("https://example.com/", opts(plug))
    end

    test "the deadline ends a hung request" do
      plug = fn conn ->
        Process.sleep(5_000)
        Plug.Conn.send_resp(conn, 200, "late")
      end

      started = System.monotonic_time(:millisecond)
      assert {:error, {:timeout, 200}} = Fetch.get("https://example.com/", opts(plug, timeout_ms: 200))
      assert System.monotonic_time(:millisecond) - started < 2_000
    end
  end

  describe "over a real connection (loopback, policy bypassed for the test)" do
    setup do
      start = fn plug_fun ->
        {:ok, pid} = Bandit.start_link(plug: {FunPlug, plug_fun}, scheme: :http, port: 0, ip: :loopback)
        {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
        "http://127.0.0.1:#{port}"
      end

      {:ok, start: start}
    end

    test "streams a body through the dedicated Finch pool", %{start: start} do
      base = start.(fn conn -> conn |> Plug.Conn.put_resp_content_type("text/plain") |> Plug.Conn.send_resp(200, "over the wire") end)
      assert {:ok, %{status: 200, body: "over the wire", ip: "127.0.0.1"}} = Fetch.get(base <> "/x", unsafe_allow_local: true)
    end

    test "is refused without the test bypass", %{start: start} do
      base = start.(fn conn -> Plug.Conn.send_resp(conn, 200, "SECRET") end)
      assert {:error, {:refused, _}} = Fetch.get(base <> "/x")
    end

    test "a chunked gzip bomb stops at the cap", %{start: start} do
      base =
        start.(fn conn ->
          conn =
            conn
            |> Plug.Conn.put_resp_header("content-type", "text/plain")
            |> Plug.Conn.put_resp_header("content-encoding", "gzip")
            |> Plug.Conn.send_chunked(200)

          z = :zlib.open()
          :zlib.deflateInit(z, :default, :deflated, 31, 8, :default)
          zeros = :binary.copy(<<0>>, @mib)

          Enum.reduce_while(1..64, conn, fn _, conn ->
            case Plug.Conn.chunk(conn, :zlib.deflate(z, zeros, :sync)) do
              {:ok, conn} -> {:cont, conn}
              {:error, _} -> {:halt, conn}
            end
          end)
        end)

      assert {:ok, r} = Fetch.get(base <> "/bomb", unsafe_allow_local: true, max_bytes: 256 * @kib)
      assert byte_size(r.body) == 256 * @kib
      assert r.body_truncated
    end

    test "follows a redirect between two local servers only with the bypass", %{start: start} do
      target = start.(fn conn -> conn |> Plug.Conn.put_resp_content_type("text/plain") |> Plug.Conn.send_resp(200, "landed") end)
      origin = start.(fn conn -> conn |> Plug.Conn.put_resp_header("location", target <> "/there") |> Plug.Conn.send_resp(301, "") end)

      assert {:ok, %{body: "landed", chain: [%{"status" => 301}, %{"status" => 200}]}} = Fetch.get(origin <> "/", unsafe_allow_local: true)
    end
  end
end
