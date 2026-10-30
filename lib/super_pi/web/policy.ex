defmodule SuperPi.Web.Policy do
  @moduledoc """
  Request-forgery policy for `web_fetch`: which URLs an agent may make the node request.

  The model controls the URL, so the node must not become a proxy into its own network. The
  rule is deny by default, allow global unicast only.

  `check_url/2` refuses a URL when:

  - the scheme is not `http` or `https`, or the URL has userinfo, a backslash or whitespace;
  - the port is not 80 or 443;
  - the host is `localhost`, `*.localhost`, `*.local`, `*.internal` or `metadata.google.internal`,
    whatever it resolves to;
  - the host is a numeric form that does not parse as one clear address (`0x7f.1`, `2130706433`
    are checked as the address they mean);
  - ANY address the host resolves to is reserved (`reserved?/1`).

  `reserved?/1` covers loopback, private, link-local (including `169.254.0.0/16`, the cloud
  metadata endpoint), CGNAT, multicast, unspecified, documentation and benchmarking ranges, and
  for IPv6 everything outside `2000::/3` (ULA `fc00::/7`, link-local `fe80::/10` and so on).
  IPv4-mapped (`::ffff:a.b.c.d`), NAT64 (`64:ff9b::/96`) and 6to4 (`2002::/16`) forms are
  unwrapped and the embedded IPv4 address is checked, so a form is refused exactly when its
  unwrapped address is.

  Redirects are followed by the caller, never by the HTTP client: at most `max_redirects/0`
  hops, and `check_url/2` runs on every hop (`redirect_url/2` resolves a `Location` value).
  A public host that redirects to `127.0.0.1` is refused at the second hop.

  The module is pure except for the default resolver. Tests and callers inject `:resolver`
  (`fn host -> {:ok, [ip]} | {:error, reason} end`) so no check touches DNS.

  ## Residual risk: DNS rebinding

  The check resolves the name, the HTTP client resolves it again when it connects. A hostile
  DNS server can answer with a public address to the first lookup and `127.0.0.1` to the
  second. `pin/2` closes the window by building a request against the checked address, and the
  fetcher uses it when `pin_ip: true`. That path is OFF by default and UNVERIFIED against the
  installed Req, Finch and Mint (TLS verification and the `Host` header need an end-to-end
  check). A deployment that cannot tolerate the window should use `network: "allowlist"` or an
  egress proxy that filters by destination address.

  ## Test-only option

  `unsafe_allow_local: true` skips the port, name and address checks so a test can reach a
  server on `127.0.0.1`. It is an option of the call and cannot come from a tool argument. It
  must never be set in production config.
  """

  import Bitwise

  @type ip :: :inet.ip_address()
  @type target :: %{uri: URI.t(), host: String.t(), ips: [ip()]}

  @max_redirects 5
  @max_url_bytes 2048
  @allowed_ports [80, 443]
  @denied_names ["localhost", "metadata.google.internal"]
  @denied_suffixes [".localhost", ".local", ".internal"]

  @doc "Maximum number of redirects a fetch follows."
  @spec max_redirects() :: pos_integer()
  def max_redirects, do: @max_redirects

  @doc """
  Checks a URL and resolves its host.

  Returns the parsed URI, the normalized host and the checked addresses, or
  `{:error, {:refused, message}}` or `{:error, {:dns, reason}}`.

  Options: `:resolver` (default `system_resolver/1`) and `:unsafe_allow_local` (test only).
  """
  @spec check_url(term(), keyword()) :: {:ok, target()} | {:error, {:refused, String.t()} | {:dns, term()}}
  def check_url(url, opts \\ []) do
    local? = Keyword.get(opts, :unsafe_allow_local, false) == true

    with {:ok, uri, host} <- parse(url, local?),
         {:ok, ips} <- addresses(host, Keyword.get(opts, :resolver, &system_resolver/1)),
         :ok <- check_addresses(ips, local?) do
      {:ok, %{uri: %{uri | host: host}, host: host, ips: ips}}
    end
  end

  @doc """
  True when an address is outside global unicast space and so must never be fetched.

  A malformed tuple counts as reserved.
  """
  @spec reserved?(term()) :: boolean()
  def reserved?({a, b, c, d}) when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255 do
    cond do
      a == 0 -> true
      a == 10 -> true
      a == 100 and b in 64..127 -> true
      a == 127 -> true
      a == 169 and b == 254 -> true
      a == 172 and b in 16..31 -> true
      a == 192 and b == 0 and c in [0, 2] -> true
      a == 192 and b == 88 and c == 99 -> true
      a == 192 and b == 168 -> true
      a == 198 and b in 18..19 -> true
      a == 198 and b == 51 and c == 100 -> true
      a == 203 and b == 0 and c == 113 -> true
      a >= 224 -> true
      true -> false
    end
  end

  def reserved?({0, 0, 0, 0, 0, 0xFFFF, hi, lo}) when hi in 0..0xFFFF and lo in 0..0xFFFF, do: reserved?(embedded(hi, lo))
  def reserved?({0x64, 0xFF9B, 0, 0, 0, 0, hi, lo}) when hi in 0..0xFFFF and lo in 0..0xFFFF, do: reserved?(embedded(hi, lo))
  def reserved?({0x2002, hi, lo, _, _, _, _, _}) when hi in 0..0xFFFF and lo in 0..0xFFFF, do: reserved?(embedded(hi, lo))

  def reserved?({w1, w2, _, _, _, _, _, _}) when w1 in 0..0xFFFF and w2 in 0..0xFFFF do
    cond do
      # 2001::/23: IETF protocol assignments, including Teredo (2001::/32) and ORCHID.
      w1 == 0x2001 and w2 < 0x200 -> true
      # 2001:db8::/32 documentation.
      w1 == 0x2001 and w2 == 0xDB8 -> true
      # 3fff::/20 documentation.
      w1 == 0x3FFF and w2 < 0x1000 -> true
      # Global unicast is 2000::/3. Everything else is reserved, ULA and link-local included.
      w1 in 0x2000..0x3FFF -> false
      true -> true
    end
  end

  def reserved?(_), do: true

  @doc "Resolves a `Location` value against the URL it came from. Never raises."
  @spec redirect_url(URI.t(), term()) :: {:ok, String.t()} | {:error, {:refused, String.t()}}
  def redirect_url(%URI{} = from, location) when is_binary(location) do
    {:ok, from |> URI.merge(String.trim(location)) |> URI.to_string()}
  rescue
    _ -> {:error, {:refused, "Redirect Location is not a valid URL."}}
  end

  def redirect_url(_from, _location), do: {:error, {:refused, "Redirect without a valid Location."}}

  @doc """
  Builds the request target for a pinned-IP connect: the URI with the checked address as host
  and the original host name for the `Host` header, SNI and certificate check.

  Unverified, see the moduledoc.
  """
  @spec pin(target(), keyword()) :: {URI.t(), String.t()}
  def pin(%{uri: uri, host: host, ips: [ip | _]}, _opts \\ []), do: {%{uri | host: ip_to_string(ip)}, host}

  @doc "Default resolver: the system resolver, IPv4 and IPv6, every address returned."
  @spec system_resolver(String.t()) :: {:ok, [ip()]} | {:error, term()}
  def system_resolver(host) do
    name = String.to_charlist(host)

    case {:inet.getaddrs(name, :inet), :inet.getaddrs(name, :inet6)} do
      {{:ok, a}, {:ok, b}} -> {:ok, Enum.uniq(a ++ b)}
      {{:ok, a}, _} -> {:ok, a}
      {_, {:ok, b}} -> {:ok, b}
      {{:error, reason}, _} -> {:error, reason}
    end
  end

  @doc "Text form of an address."
  @spec ip_to_string(ip()) :: String.t()
  def ip_to_string(ip), do: ip |> :inet.ntoa() |> to_string()

  # --- URL parsing ---------------------------------------------------------------------------

  defp parse(url, local?) when is_binary(url) do
    url = String.trim(url)

    cond do
      url == "" -> refuse("The URL is empty.")
      byte_size(url) > @max_url_bytes -> refuse("The URL is longer than #{@max_url_bytes} bytes.")
      String.contains?(url, "\\") -> refuse("The URL contains a backslash.")
      Regex.match?(~r/[\x00-\x20\x7f]/, url) -> refuse("The URL contains whitespace or control characters.")
      true -> parse_uri(URI.parse(url), local?)
    end
  end

  defp parse(_url, _local?), do: refuse("The URL must be a string.")

  defp parse_uri(%URI{scheme: scheme} = uri, local?) do
    scheme = if is_binary(scheme), do: String.downcase(scheme)
    host = normalize_host(uri.host)

    cond do
      scheme not in ["http", "https"] -> refuse("Only http and https URLs are allowed.")
      uri.userinfo != nil -> refuse("URLs with credentials (user:password@) are not allowed.")
      host == "" -> refuse("The URL has no host.")
      not local? and effective_port(uri, scheme) not in @allowed_ports -> refuse("Only ports 80 and 443 are allowed.")
      not local? and denied_name?(host) -> refuse("The host `#{host}` is not allowed.")
      not host_syntax?(host) -> refuse("The host `#{host}` is not a valid ASCII host name or address.")
      true -> {:ok, %{uri | scheme: scheme}, host}
    end
  end

  defp normalize_host(nil), do: ""
  defp normalize_host(host), do: host |> String.downcase() |> String.trim_trailing(".")

  defp effective_port(%URI{port: port}, _scheme) when is_integer(port), do: port
  defp effective_port(_uri, "https"), do: 443
  defp effective_port(_uri, _scheme), do: 80

  defp denied_name?(host), do: host in @denied_names or Enum.any?(@denied_suffixes, &String.ends_with?(host, &1))

  defp host_syntax?(host) do
    if String.contains?(host, ":") do
      match?({:ok, _}, :inet.parse_strict_address(String.to_charlist(host)))
    else
      Regex.match?(~r/\A[a-z0-9._-]+\z/, host)
    end
  end

  # --- Resolution ----------------------------------------------------------------------------

  defp addresses(host, resolver) do
    case literal(host) do
      {:ok, ip} ->
        {:ok, [ip]}

      :numeric_unparsable ->
        refuse("The host `#{host}` looks like a numeric address but is not a valid one.")

      :name ->
        case safe_resolve(resolver, host) do
          {:ok, [_ | _] = ips} -> {:ok, ips}
          {:ok, _} -> {:error, {:dns, :no_addresses}}
          {:error, reason} -> {:error, {:dns, reason}}
        end
    end
  end

  defp literal(host) do
    chars = String.to_charlist(host)

    case :inet.parse_strict_address(chars) do
      {:ok, ip} ->
        {:ok, ip}

      {:error, _} ->
        if numeric_host?(host) do
          case :inet.parse_address(chars) do
            {:ok, ip} -> {:ok, ip}
            {:error, _} -> :numeric_unparsable
          end
        else
          :name
        end
    end
  end

  # `0x7f.1`, `2130706433`, `0177.0.0.1`: the system resolver reads these as addresses. Like browsers,
  # any host whose last label is a number counts as one, so `999.1.1.1.1` is refused, not looked up.
  # A regex literal stays in a function body, not a module attribute (not allowed on OTP 28).
  defp numeric_host?(host), do: Regex.match?(~r/(\A|\.)(0x[0-9a-f]*|\d+)\z/i, host)

  # A resolver that raises or exits must not crash the caller.
  defp safe_resolve(resolver, host) do
    case resolver.(host) do
      {:ok, ips} when is_list(ips) -> {:ok, ips}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:bad_resolver_reply, other}}
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp check_addresses(_ips, true), do: :ok

  defp check_addresses(ips, false) do
    case Enum.find(ips, &reserved?/1) do
      nil -> :ok
      ip -> refuse("The host resolves to a reserved address (#{inspect_ip(ip)}).")
    end
  end

  defp inspect_ip(ip) do
    ip_to_string(ip)
  rescue
    _ -> inspect(ip)
  end

  # The IPv4 address held in the last two 16-bit words of a mapped, NAT64 or 6to4 form.
  defp embedded(hi, lo), do: {hi >>> 8, hi &&& 0xFF, lo >>> 8, lo &&& 0xFF}

  defp refuse(message), do: {:error, {:refused, message}}
end
