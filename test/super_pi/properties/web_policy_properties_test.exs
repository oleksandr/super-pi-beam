defmodule SuperPi.Properties.WebPolicyTest do
  @moduledoc """
  The request-forgery policy is where `web_fetch` can hurt, so it is checked against ranges the test
  writes down on its own, not against the implementation's tables:

  - every reserved address is refused and every global unicast address is allowed, whatever the
    scheme, port, host case or trailing dot;
  - an IPv4-mapped, NAT64 or 6to4 form is refused exactly when the IPv4 address inside it is;
  - a public host that redirects to a reserved address is refused.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Bitwise

  alias SuperPi.Web.{Fetch, Policy}

  @public {93, 184, 216, 34}

  # --- Independent model of the reserved space ----------------------------------------------

  @v4_reserved [
    {{0, 0, 0, 0}, 8},
    {{10, 0, 0, 0}, 8},
    {{100, 64, 0, 0}, 10},
    {{127, 0, 0, 0}, 8},
    {{169, 254, 0, 0}, 16},
    {{172, 16, 0, 0}, 12},
    {{192, 0, 0, 0}, 24},
    {{192, 0, 2, 0}, 24},
    {{192, 88, 99, 0}, 24},
    {{192, 168, 0, 0}, 16},
    {{198, 18, 0, 0}, 15},
    {{198, 51, 100, 0}, 24},
    {{203, 0, 113, 0}, 24},
    {{224, 0, 0, 0}, 3}
  ]

  # First octets that hold no special-purpose block at all, so any address under them is global unicast.
  @v4_public_octets Enum.to_list(1..9) ++
                      Enum.to_list(11..99) ++
                      Enum.to_list(101..126) ++
                      Enum.to_list(128..168) ++
                      [170, 171] ++
                      Enum.to_list(173..191) ++
                      Enum.to_list(193..197) ++ Enum.to_list(199..202) ++ Enum.to_list(204..223)

  defp v4_int({a, b, c, d}), do: a <<< 24 ||| b <<< 16 ||| c <<< 8 ||| d
  defp v4_tuple(n), do: {n >>> 24 &&& 255, n >>> 16 &&& 255, n >>> 8 &&& 255, n &&& 255}

  defp v4_in_block(base, prefix) do
    size = 1 <<< (32 - prefix)
    start = v4_int(base) &&& bnot(size - 1)
    map(integer(0..(size - 1)), &v4_tuple(start + &1))
  end

  defp reserved_v4,
    do: @v4_reserved |> Enum.map(fn {base, prefix} -> v4_in_block(base, prefix) end) |> one_of()

  defp public_v4 do
    gen(
      all(
        a <- member_of(@v4_public_octets),
        b <- integer(0..255),
        c <- integer(0..255),
        d <- integer(0..255),
        do: {a, b, c, d}
      )
    )
  end

  defp any_v4 do
    gen(
      all(
        a <- integer(0..255),
        b <- integer(0..255),
        c <- integer(0..255),
        d <- integer(0..255),
        do: {a, b, c, d}
      )
    )
  end

  defp words(n), do: list_of(integer(0..0xFFFF), length: n)

  defp reserved_v6 do
    tail = words(7)

    one_of([
      constant({0, 0, 0, 0, 0, 0, 0, 0}),
      constant({0, 0, 0, 0, 0, 0, 0, 1}),
      # fc00::/7 unique local
      map({integer(0xFC00..0xFDFF), tail}, fn {w, t} -> List.to_tuple([w | t]) end),
      # fe80::/10 link-local
      map({integer(0xFE80..0xFEBF), tail}, fn {w, t} -> List.to_tuple([w | t]) end),
      # ff00::/8 multicast
      map({integer(0xFF00..0xFFFF), tail}, fn {w, t} -> List.to_tuple([w | t]) end),
      # 2001:db8::/32 documentation
      map(words(6), fn t -> List.to_tuple([0x2001, 0xDB8 | t]) end),
      # Outside 2000::/3 and not a mapped or NAT64 form: 0100::/8 up to 1fff, and 4000::/3 up.
      map({one_of([integer(0x0100..0x1FFF), integer(0x4000..0xFEFF)]), tail}, fn {w, t} ->
        List.to_tuple([w | t])
      end)
    ])
  end

  defp public_v6 do
    # 2400::/12 up to 3ffe: no 2001, 2002 or 3fff special blocks.
    map({integer(0x2400..0x3FFE), words(7)}, fn {w, t} -> List.to_tuple([w | t]) end)
  end

  defp v6_text(ip), do: "[" <> to_string(:inet.ntoa(ip)) <> "]"
  defp v4_text(ip), do: to_string(:inet.ntoa(ip))

  defp mixed_case(host, seed) do
    host
    |> String.graphemes()
    |> Enum.with_index()
    |> Enum.map_join(fn {g, i} -> if rem(i + seed, 2) == 0, do: String.upcase(g), else: g end)
  end

  # {scheme as sent, port suffix}: the scheme may be upper case, the port is the default or absent.
  defp shape do
    gen all(
          plain <- member_of(["http", "https"]),
          port <- member_of([:none, :default]),
          upper? <- boolean()
        ) do
      suffix = if port == :none, do: "", else: if(plain == "http", do: ":80", else: ":443")
      {if(upper?, do: String.upcase(plain), else: plain), suffix}
    end
  end

  defp url({scheme, suffix}, host), do: "#{scheme}://#{host}#{suffix}/path?q=1"

  defp refused?(result), do: match?({:error, {:refused, _}}, result)

  # A literal must never reach the resolver.
  defp check_literal(host, shape),
    do:
      Policy.check_url(url(shape, host),
        resolver: fn _ -> flunk("resolver called for a literal") end
      )

  # --- Properties ----------------------------------------------------------------------------

  property "every reserved IPv4 address is refused, every public one is allowed (literal and resolved)" do
    check all(
            reserved <- reserved_v4(),
            public <- public_v4(),
            shape <- shape(),
            seed <- integer(0..1)
          ) do
      assert Policy.reserved?(reserved), inspect(reserved)
      refute Policy.reserved?(public), inspect(public)

      assert refused?(check_literal(v4_text(reserved), shape))
      assert {:ok, _} = check_literal(v4_text(public), shape)

      name = mixed_case("host.example", seed)

      assert refused?(Policy.check_url(url(shape, name), resolver: fn _ -> {:ok, [reserved]} end))
      assert {:ok, _} = Policy.check_url(url(shape, name), resolver: fn _ -> {:ok, [public]} end)
      # The trailing dot does not change the verdict.
      assert refused?(
               Policy.check_url(url(shape, name <> "."), resolver: fn _ -> {:ok, [reserved]} end)
             )

      assert {:ok, _} =
               Policy.check_url(url(shape, name <> "."), resolver: fn _ -> {:ok, [public]} end)
    end
  end

  property "every reserved IPv6 address is refused, every public one is allowed" do
    check all(
            reserved <- reserved_v6(),
            public <- public_v6(),
            shape <- shape(),
            upcase? <- boolean()
          ) do
      assert Policy.reserved?(reserved), inspect(reserved)
      refute Policy.reserved?(public), inspect(public)

      text = fn ip -> if upcase?, do: String.upcase(v6_text(ip)), else: v6_text(ip) end
      assert refused?(check_literal(text.(reserved), shape))
      assert {:ok, _} = check_literal(text.(public), shape)

      assert refused?(
               Policy.check_url("https://v6.example/", resolver: fn _ -> {:ok, [reserved]} end)
             )

      assert {:ok, _} =
               Policy.check_url("https://v6.example/", resolver: fn _ -> {:ok, [public]} end)
    end
  end

  property "one reserved address among public ones refuses the host, in any position" do
    check all(
            reserved <- reserved_v4(),
            public <- list_of(public_v4(), min_length: 1, max_length: 4),
            index <- integer(0..4)
          ) do
      ips = List.insert_at(public, min(index, length(public)), reserved)

      assert refused?(
               Policy.check_url("https://multi.example/", resolver: fn _ -> {:ok, ips} end)
             )
    end
  end

  property "an IPv4-mapped, NAT64 or 6to4 form is refused exactly when the inner IPv4 address is" do
    check all({a, b, c, d} = v4 <- any_v4(), tail <- words(5)) do
      hi = a <<< 8 ||| b
      lo = c <<< 8 ||| d
      [t1, t2, t3, t4, t5] = tail

      mapped = {0, 0, 0, 0, 0, 0xFFFF, hi, lo}
      nat64 = {0x64, 0xFF9B, 0, 0, 0, 0, hi, lo}
      six_to_four = {0x2002, hi, lo, t1, t2, t3, t4, t5}

      expected = Policy.reserved?(v4)
      assert Policy.reserved?(mapped) == expected, inspect(mapped)
      assert Policy.reserved?(nat64) == expected, inspect(nat64)
      assert Policy.reserved?(six_to_four) == expected, inspect(six_to_four)

      # The same through a URL, in the textual forms a client would send.
      assert refused?(Policy.check_url("http://#{v6_text(mapped)}/", [])) == expected
      assert refused?(Policy.check_url("http://#{v6_text(six_to_four)}/", [])) == expected
    end
  end

  property "a malformed address is never allowed" do
    check all(
            junk <-
              one_of([
                list_of(integer(), max_length: 9) |> map(&List.to_tuple/1),
                binary(),
                integer()
              ])
          ) do
      valid? = match?({_, _, _, _}, junk) and Enum.all?(Tuple.to_list(junk), &(&1 in 0..255))

      valid6? =
        match?({_, _, _, _, _, _, _, _}, junk) and
          Enum.all?(Tuple.to_list(junk), &(&1 in 0..0xFFFF))

      if not (valid? or valid6?), do: assert(Policy.reserved?(junk))
    end
  end

  property "a public host that redirects to a reserved address is refused, and the target is never requested" do
    check all(
            reserved <- one_of([reserved_v4(), reserved_v6()]),
            scheme <- member_of(["http", "https"]),
            max_runs: 40
          ) do
      host = if tuple_size(reserved) == 4, do: v4_text(reserved), else: v6_text(reserved)
      location = "#{scheme}://#{host}/admin"

      plug = fn conn ->
        if conn.host == "public.example" do
          conn |> Plug.Conn.put_resp_header("location", location) |> Plug.Conn.send_resp(302, "")
        else
          flunk("the redirect target was requested: #{conn.host}")
        end
      end

      assert {:error, {:refused, _}} =
               Fetch.get("https://public.example/",
                 resolver: fn _ -> {:ok, [@public]} end,
                 req_options: [plug: plug]
               )
    end
  end

  property "a redirect to a public address is followed" do
    check all(public <- public_v4(), max_runs: 20) do
      plug = fn conn ->
        case conn.host do
          "public.example" ->
            conn
            |> Plug.Conn.put_resp_header("location", "http://#{v4_text(public)}/ok")
            |> Plug.Conn.send_resp(302, "")

          _ ->
            conn
            |> Plug.Conn.put_resp_content_type("text/plain")
            |> Plug.Conn.send_resp(200, "fine")
        end
      end

      assert {:ok, %{body: "fine"}} =
               Fetch.get("https://public.example/",
                 resolver: fn _ -> {:ok, [@public]} end,
                 req_options: [plug: plug]
               )
    end
  end

  property "the verdict never depends on host case or a trailing dot for names that are denied" do
    check all(
            name <-
              member_of([
                "localhost",
                "foo.local",
                "db.internal",
                "metadata.google.internal",
                "x.localhost"
              ]),
            seed <- integer(0..1),
            dot <- member_of(["", "."]),
            shape <- shape()
          ) do
      assert refused?(
               Policy.check_url(url(shape, mixed_case(name, seed) <> dot),
                 resolver: fn _ -> {:ok, [@public]} end
               )
             )
    end
  end

  property "a port other than 80 and 443 is always refused" do
    check all(
            port <- one_of([integer(1..79), integer(81..442), integer(444..65_535)]),
            scheme <- member_of(["http", "https"])
          ) do
      assert refused?(
               Policy.check_url("#{scheme}://example.com:#{port}/",
                 resolver: fn _ -> {:ok, [@public]} end
               )
             )
    end
  end
end
