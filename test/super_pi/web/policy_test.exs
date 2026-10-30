defmodule SuperPi.Web.PolicyTest do
  use ExUnit.Case, async: true

  alias SuperPi.Web.Policy

  @public {93, 184, 216, 34}

  defp resolver(map), do: fn host -> Map.get(map, host, {:error, :nxdomain}) end
  defp public_resolver, do: fn _ -> {:ok, [@public]} end

  defp check(url, opts \\ []),
    do: Policy.check_url(url, Keyword.put_new(opts, :resolver, public_resolver()))

  defp refused?(result), do: match?({:error, {:refused, _}}, result)

  describe "URL syntax" do
    test "accepts a plain https and http URL" do
      assert {:ok, %{host: "example.com", ips: [@public]}} = check("https://example.com/a?b=1")
      assert {:ok, %{host: "example.com"}} = check("http://example.com:80/")
      assert {:ok, %{host: "example.com"}} = check("https://example.com:443/")
    end

    test "refuses other schemes" do
      for url <- [
            "ftp://example.com/",
            "file:///etc/passwd",
            "gopher://example.com/",
            "javascript:alert(1)",
            "example.com/path",
            "//example.com/"
          ] do
        assert refused?(check(url)), url
      end
    end

    test "refuses userinfo" do
      assert {:error, {:refused, msg}} = check("https://user:pw@example.com/")
      assert msg =~ "credentials"
      assert refused?(check("https://user@example.com/"))
      assert refused?(check("https://example.com@evil.example/"))
    end

    test "refuses ports other than 80 and 443" do
      for port <- [22, 25, 8080, 8443, 6379, 5432, 9200],
          do: assert(refused?(check("http://example.com:#{port}/")), "port #{port}")
    end

    test "refuses a backslash, whitespace and control characters" do
      assert refused?(check("http://example.com\\@127.0.0.1/"))
      assert refused?(check("http://exa mple.com/"))
      assert refused?(check("http://example.com/\r\nHost: evil"))
    end

    test "refuses non-string, empty and oversized input" do
      assert refused?(check(nil))
      assert refused?(check(""))
      assert refused?(check("   "))
      assert refused?(check("http://example.com/" <> String.duplicate("a", 3000)))
    end

    test "refuses a non-ASCII host" do
      assert refused?(check("http://exämple.com/"))
    end
  end

  describe "host names" do
    test "denies local names whatever they resolve to" do
      for host <- [
            "localhost",
            "LOCALHOST",
            "localhost.",
            "foo.localhost",
            "printer.local",
            "db.internal",
            "metadata.google.internal",
            "a.b.metadata.google.internal"
          ] do
        assert {:error, {:refused, msg}} = check("http://#{host}/"), host
        assert msg =~ "not allowed"
      end
    end

    test "does not deny names that only contain the words" do
      assert {:ok, _} = check("http://localhost.example.com/")
      assert {:ok, _} = check("http://internal.example.com/")
      assert {:ok, _} = check("http://notlocal.com/")
    end

    test "normalizes case and a trailing dot before the check" do
      assert {:ok, %{host: "example.com"}} = check("HTTPS://Example.COM./")
    end
  end

  describe "resolution" do
    test "refuses when ANY returned address is reserved" do
      r = resolver(%{"mixed.example" => {:ok, [@public, {10, 0, 0, 5}]}})
      assert {:error, {:refused, msg}} = Policy.check_url("http://mixed.example/", resolver: r)
      assert msg =~ "10.0.0.5"
    end

    test "refuses a name that resolves to loopback, link-local metadata and private ranges" do
      for ip <- [
            {127, 0, 0, 1},
            {169, 254, 169, 254},
            {192, 168, 1, 1},
            {172, 16, 0, 1},
            {100, 64, 0, 1},
            {0, 0, 0, 0},
            {0, 0, 0, 0, 0, 0, 0, 1}
          ] do
        assert refused?(
                 Policy.check_url("http://sneaky.example/", resolver: fn _ -> {:ok, [ip]} end)
               ),
               inspect(ip)
      end
    end

    test "reports a failed or empty lookup as a DNS error" do
      assert {:error, {:dns, :nxdomain}} =
               Policy.check_url("http://gone.example/", resolver: resolver(%{}))

      assert {:error, {:dns, :no_addresses}} =
               Policy.check_url("http://empty.example/", resolver: fn _ -> {:ok, []} end)
    end

    test "survives a resolver that raises, exits or answers garbage" do
      assert {:error, {:dns, _}} =
               Policy.check_url("http://x.example/", resolver: fn _ -> raise "boom" end)

      assert {:error, {:dns, _}} =
               Policy.check_url("http://x.example/", resolver: fn _ -> exit(:down) end)

      assert {:error, {:dns, _}} =
               Policy.check_url("http://x.example/", resolver: fn _ -> :nonsense end)
    end

    test "checks an IP literal without calling the resolver" do
      boom = fn _ -> flunk("resolver called for a literal") end
      assert refused?(Policy.check_url("http://127.0.0.1/", resolver: boom))

      assert refused?(
               Policy.check_url("http://169.254.169.254/latest/meta-data/", resolver: boom)
             )

      assert refused?(Policy.check_url("http://[::1]/", resolver: boom))
      assert refused?(Policy.check_url("http://[fd00::1]/", resolver: boom))
      assert {:ok, %{ips: [@public]}} = Policy.check_url("http://93.184.216.34/", resolver: boom)
    end

    test "numeric host forms are read as the address they mean" do
      for host <- ["2130706433", "0x7f.1", "0177.0.0.1", "127.1", "0x7f000001"] do
        assert refused?(check("http://#{host}/")), host
      end

      assert refused?(check("http://999.1.1.1.1/"))
    end

    test "IPv6 literals in brackets and mapped forms" do
      assert refused?(check("http://[::ffff:127.0.0.1]/"))
      assert refused?(check("http://[::ffff:7f00:1]/"))
      assert refused?(check("http://[2002:7f00:1::]/"))
      assert {:ok, _} = check("http://[2606:4700:4700::1111]/")
    end
  end

  describe "reserved?/1" do
    test "IPv4 ranges" do
      reserved = [
        {0, 1, 2, 3},
        {10, 1, 1, 1},
        {100, 64, 0, 1},
        {100, 127, 255, 255},
        {127, 0, 0, 1},
        {169, 254, 169, 254},
        {172, 16, 0, 1},
        {172, 31, 255, 255},
        {192, 0, 0, 1},
        {192, 0, 2, 1},
        {192, 168, 0, 1},
        {198, 18, 0, 1},
        {198, 19, 255, 255},
        {198, 51, 100, 1},
        {203, 0, 113, 1},
        {224, 0, 0, 1},
        {239, 255, 255, 255},
        {240, 0, 0, 1},
        {255, 255, 255, 255}
      ]

      allowed = [
        {1, 1, 1, 1},
        {8, 8, 8, 8},
        {100, 63, 255, 255},
        {100, 128, 0, 0},
        {172, 15, 255, 255},
        {172, 32, 0, 0},
        {169, 253, 0, 1},
        {169, 255, 0, 1},
        {198, 20, 0, 1},
        {93, 184, 216, 34},
        {223, 255, 255, 255}
      ]

      for ip <- reserved, do: assert(Policy.reserved?(ip), inspect(ip))
      for ip <- allowed, do: refute(Policy.reserved?(ip), inspect(ip))
    end

    test "IPv6 ranges" do
      reserved = [
        {0, 0, 0, 0, 0, 0, 0, 0},
        {0, 0, 0, 0, 0, 0, 0, 1},
        {0xFC00, 0, 0, 0, 0, 0, 0, 1},
        {0xFD12, 0x3456, 0, 0, 0, 0, 0, 1},
        {0xFE80, 0, 0, 0, 0, 0, 0, 1},
        {0xFEC0, 0, 0, 0, 0, 0, 0, 1},
        {0xFF02, 0, 0, 0, 0, 0, 0, 1},
        {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1},
        {0x2001, 0, 0, 0, 0, 0, 0, 1},
        {0x100, 0, 0, 0, 0, 0, 0, 1}
      ]

      allowed = [
        {0x2606, 0x4700, 0x4700, 0, 0, 0, 0, 0x1111},
        {0x2001, 0x4860, 0x4860, 0, 0, 0, 0, 0x8888},
        {0x2A00, 0x1450, 0, 0, 0, 0, 0, 0x64}
      ]

      for ip <- reserved, do: assert(Policy.reserved?(ip), inspect(ip))
      for ip <- allowed, do: refute(Policy.reserved?(ip), inspect(ip))
    end

    test "IPv4-mapped, NAT64 and 6to4 forms follow the embedded address" do
      assert Policy.reserved?({0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1})
      assert Policy.reserved?({0, 0, 0, 0, 0, 0xFFFF, 0xA9FE, 0xA9FE})
      refute Policy.reserved?({0, 0, 0, 0, 0, 0xFFFF, 0x5DB8, 0xD822})
      assert Policy.reserved?({0x64, 0xFF9B, 0, 0, 0, 0, 0x7F00, 1})
      refute Policy.reserved?({0x64, 0xFF9B, 0, 0, 0, 0, 0x5DB8, 0xD822})
      assert Policy.reserved?({0x2002, 0x7F00, 1, 0, 0, 0, 0, 1})
      assert Policy.reserved?({0x2002, 0xA9FE, 0xA9FE, 1, 2, 3, 4, 5})
      refute Policy.reserved?({0x2002, 0x5DB8, 0xD822, 1, 2, 3, 4, 5})
    end

    test "a malformed address is reserved" do
      assert Policy.reserved?({256, 0, 0, 1})
      assert Policy.reserved?({1, 2, 3})
      assert Policy.reserved?(:nope)
      assert Policy.reserved?({0x10000, 0, 0, 0, 0, 0, 0, 1})
    end
  end

  describe "redirects" do
    test "redirect_url/2 resolves a relative, absolute and scheme-relative Location" do
      from = URI.parse("https://example.com/a/b")
      assert {:ok, "https://example.com/c"} = Policy.redirect_url(from, "/c")
      assert {:ok, "https://example.com/a/d"} = Policy.redirect_url(from, "d")
      assert {:ok, "http://other.example/x"} = Policy.redirect_url(from, "http://other.example/x")
      assert {:ok, "https://other.example/x"} = Policy.redirect_url(from, "//other.example/x")
      assert refused?(Policy.redirect_url(from, nil))
    end

    test "a redirect target gets the full check" do
      from = URI.parse("https://example.com/")
      {:ok, next} = Policy.redirect_url(from, "http://127.0.0.1/admin")
      assert refused?(check(next))
      {:ok, next} = Policy.redirect_url(from, "http://169.254.169.254/latest/meta-data/")
      assert refused?(check(next))
      {:ok, next} = Policy.redirect_url(from, "ftp://example.com/")
      assert refused?(check(next))
    end

    test "the limit is five" do
      assert Policy.max_redirects() == 5
    end
  end

  describe "unsafe_allow_local (test-only)" do
    test "skips the port, name and address checks, and nothing else" do
      assert {:ok, %{ips: [{127, 0, 0, 1}]}} =
               Policy.check_url("http://127.0.0.1:4567/", unsafe_allow_local: true)

      assert {:ok, _} =
               Policy.check_url("http://localhost:4567/",
                 unsafe_allow_local: true,
                 resolver: fn _ -> {:ok, [{127, 0, 0, 1}]} end
               )

      assert refused?(Policy.check_url("ftp://127.0.0.1/", unsafe_allow_local: true))
      assert refused?(Policy.check_url("http://u:p@127.0.0.1/", unsafe_allow_local: true))
    end

    test "is off by default" do
      assert refused?(Policy.check_url("http://127.0.0.1:4567/"))
    end
  end

  describe "pin/1" do
    test "builds the target from the checked address and keeps the host name" do
      {:ok, target} = check("https://example.com/path?q=1")
      {uri, hostname} = Policy.pin(target)
      assert uri.host == "93.184.216.34"
      assert uri.path == "/path"
      assert hostname == "example.com"
    end
  end
end
