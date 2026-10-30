### Web access (`web` plugin)

`SuperPi.Plugins.Web` gives an agent `web_fetch`, and `web_search` when a search provider is configured. The Assistant harness loads it with `{Plugins.Web, tools: [:fetch, :search]}`, the Librarian bare.

| Tool | Arguments | Effect |
|---|---|---|
| `web_fetch` | `url`, `format` (`markdown`, `text`, `raw`), `max_chars`, `offset`, `artifact` | `net_read` |
| `web_search` | `query`, `max_results` | `net_read` |

There is no `headers` argument. A long page is cut at `max_chars` (default 20,000, most 100,000) with a note that names the `offset` to continue from. `artifact` saves the full text under a name instead of returning it. A text over 200,000 characters is saved automatically. A PDF or other binary file is refused unless `artifact` is set.

`web_fetch` returns the page in `output`, metadata in `structured_output` (`final_url`, `status`, `content_type`, `bytes`, `chars`, `truncated`, `title`, up to 30 `links`, `artifact`) and the redirect chain, resolved address and duration in `details`. A 4xx or 5xx status, a refused URL or content type, and a timeout set `is_error`.

**Request-forgery policy.** A URL is refused when it has credentials, a scheme other than `http` or `https`, or a port other than 80 and 443. The host must not be `localhost`, `*.local`, `*.internal` or `metadata.google.internal`, and ANY address it resolves to must be global unicast. Loopback, private, link-local (including `169.254.169.254`), CGNAT, multicast and IPv6 ULA and link-local addresses are refused, and IPv4-mapped, NAT64 and 6to4 forms are checked as the IPv4 address inside. Redirects are followed by the tool, at most five, with the full check on every hop.

**Residual risk.** DNS can answer differently between the check and the connect (rebinding). `pin_ip: true` in the plugin's `fetch:` options connects to the checked address, but it is off by default and not verified against the installed Req, Finch and Mint. Where the window is not acceptable, set `network: "allowlist"` or route egress through a filtering proxy.

**Limits.** The size cap counts decoded bytes: the response streams undecoded, and the tool inflates `gzip` and `deflate` itself and stops at `max_bytes` (default 2 MiB, at most 8 MiB), so a gzip bomb cannot grow the heap. The fetch and the HTML conversion run under `SandboxRunner.run_isolated/2` (deadline and heap limit). Requests use their own Finch pool, `SuperPi.WebFinch`.

**Permissions.** `net_read` is allowed in `plan` (unless `network_in_plan_mode: false`), `accept-edits` and `auto`. `network: "deny"` refuses both tools. `network: "allowlist"` checks the `url` host, so `web_search` is refused under it. A workspace with `"network": false` does not offer them.

**Search providers.** `web_search` exists only when a provider has its key or URL. Set one with the plugin option `search:`, `config :super_pi, :web_search`, or `SUPER_PI_WEB_SEARCH`.

| Provider | Value | Credentials |
|---|---|---|
| Brave Search | `brave` | `BRAVE_API_KEY` |
| Tavily | `tavily` | `TAVILY_API_KEY` |
| SearxNG (JSON format enabled) | `searxng` | `SEARXNG_URL` |

```elixir
{Plugins.Web, tools: [:fetch, :search], search: {:brave, api_key: System.fetch_env!("BRAVE_API_KEY")}}
```
