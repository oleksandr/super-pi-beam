defmodule SuperPi.Plugins.WebTest do
  @moduledoc """
  The plugin end to end, offline: HTTP goes to a `plug:` function through the plugin's `fetch:` option.
  """
  use SuperPi.DataCase, async: false

  alias SuperPi.Artifacts
  alias SuperPi.Durable.Storage
  alias SuperPi.Env.Workspace
  alias SuperPi.Plugins
  alias SuperPi.Plugins.{Permissions, Web}
  alias SuperPi.Tools

  @public {93, 184, 216, 34}

  defp conv!(agent \\ %{}) do
    app = Path.join(System.tmp_dir!(), "web_#{System.unique_integer([:positive])}")
    File.mkdir_p!(app)
    on_exit(fn -> File.rm_rf(app) end)

    Storage.create_conversation!(
      agent: Map.merge(%{"workspacePaths" => [File.cwd!()], "appDataDir" => app}, agent)
    )
  end

  defp config(plug, extra) do
    {fetch, rest} = Keyword.pop(extra, :fetch, [])
    [fetch: [resolver: fn _ -> {:ok, [@public]} end, req_options: [plug: plug]] ++ fetch] ++ rest
  end

  defp call(args, plug, opts \\ []) do
    conv = Keyword.get_lazy(opts, :conv, &conv!/0)
    ctx = %{conversation_id: conv.id, config: config(plug, Keyword.get(opts, :config, []))}
    Web.wrap_tool("web_fetch", args, fn _ -> flunk("next called") end, ctx)
  end

  defp page(body, type \\ "text/html"),
    do: fn conn ->
      conn |> Plug.Conn.put_resp_content_type(type) |> Plug.Conn.send_resp(200, body)
    end

  defp never, do: fn _conn -> flunk("a request was made") end

  describe "tool offer" do
    test "web_fetch always, web_search only with a usable provider" do
      assert [%{"name" => "web_fetch"}] = Web.tool_specs([])
      assert [%{"name" => "web_fetch"}] = Web.tool_specs(tools: [:fetch, :search])

      assert [%{"name" => "web_fetch"}, %{"name" => "web_search"}] =
               Web.tool_specs(search: {:brave, api_key: "k"})

      assert [%{"name" => "web_fetch"}, %{"name" => "web_search"}] =
               Web.tool_specs(tools: [:fetch, :search], search: {:tavily, api_key: "k"})

      assert [%{"name" => "web_fetch"}] =
               Web.tool_specs(tools: [:fetch], search: {:brave, api_key: "k"})

      assert [%{"name" => "web_fetch"}] = Web.tool_specs(search: {:brave, api_key: ""})
    end

    test "before_agent_start appends the specs, once, and drops a stale web_search" do
      ctx = %{config: [search: {:brave, api_key: "k"}]}
      {:ok, cfg} = Web.before_agent_start(%{"tools" => [%{"name" => "todo"}]}, ctx)
      assert Enum.map(cfg["tools"], & &1["name"]) == ["todo", "web_fetch", "web_search"]
      assert {:ok, ^cfg} = Web.before_agent_start(cfg, ctx)

      {:ok, no_search} = Web.before_agent_start(cfg, %{config: []})
      assert Enum.map(no_search["tools"], & &1["name"]) == ["todo", "web_fetch"]
    end

    test "the specs declare net_read, take no headers and say so in the schema" do
      for spec <- Web.tool_specs(search: {:brave, api_key: "k"}) do
        assert spec["effects"] == ["net_read"]
        assert spec["parameters"]["additionalProperties"] == false
        refute Map.has_key?(spec["parameters"]["properties"], "headers")
      end

      fetch = hd(Web.tool_specs())

      assert Map.keys(fetch["parameters"]["properties"]) |> Enum.sort() == [
               "artifact",
               "format",
               "max_chars",
               "offset",
               "url"
             ]

      assert fetch["parameters"]["required"] == ["url"]
    end

    test "the tools are not in the global catalog" do
      Tools.ensure_catalog_ets!()
      names = Enum.map(Tools.active_llm_tools(), & &1["name"])
      refute "web_fetch" in names
      refute "web_search" in names
    end

    test "the plugin is registered as web" do
      assert Plugins.resolve("web") == Web
      assert Web in Plugins.list()
      assert {Web, [tools: [:fetch]]} = Plugins.resolve({"web", tools: [:fetch]})
    end

    test "a workspace without network hides both tools" do
      tools = Web.tool_specs(search: {:brave, api_key: "k"})

      names = fn ws ->
        tools
        |> Workspace.offered_tools(%{"workspace" => ws, "tools" => tools})
        |> Enum.map(& &1["name"])
        |> Enum.filter(&String.starts_with?(&1, "web_"))
      end

      assert names.(%{"kind" => "none"}) == ["web_fetch", "web_search"]
      assert names.(%{"kind" => "none", "network" => false}) == []
    end

    test "other tools pass through wrap_tool" do
      assert :passed = Web.wrap_tool("todo", %{}, fn _ -> :passed end, %{config: []})
      assert :passed = Web.wrap_tool("web_search", %{}, fn _ -> :passed end, %{config: []})
    end
  end

  describe "permissions" do
    defp check(conv, args \\ %{"url" => "https://example.com"}),
      do: Permissions.before_tool("web_fetch", args, %{conversation_id: conv.id})

    defp agent(mode, extra \\ %{}),
      do:
        Map.merge(
          %{"executionMode" => mode, "tools" => Web.tool_specs(search: {:brave, api_key: "k"})},
          extra
        )

    test "allowed in accept-edits and in plan mode (network_in_plan_mode defaults to true)" do
      assert :allow = check(conv!(agent("accept-edits")))
      assert :allow = check(conv!(agent("plan")))
      assert :allow = check(conv!(agent("auto")))
    end

    test "blocked in plan mode when network_in_plan_mode is false" do
      assert {:block, _} =
               check(
                 conv!(agent("plan", %{"settingsOverride" => %{"network_in_plan_mode" => false}}))
               )
    end

    test "blocked under network: deny in every mode but plan reports the mode block" do
      for mode <- ["accept-edits", "auto"] do
        assert {:block, msg} =
                 check(conv!(agent(mode, %{"settingsOverride" => %{"network" => "deny"}})))

        assert msg =~ "network"
      end

      assert {:block, _} =
               check(conv!(agent("plan", %{"settingsOverride" => %{"network" => "deny"}})))
    end

    test "web_search follows the same rules" do
      conv = conv!(agent("accept-edits"))

      assert :allow =
               Permissions.before_tool("web_search", %{"query" => "x"}, %{
                 conversation_id: conv.id
               })

      denied = conv!(agent("accept-edits", %{"settingsOverride" => %{"network" => "deny"}}))

      assert {:block, _} =
               Permissions.before_tool("web_search", %{"query" => "x"}, %{
                 conversation_id: denied.id
               })
    end

    test "network: allowlist checks the url host" do
      settings = %{
        "settingsOverride" => %{"network" => "allowlist", "networkAllowHosts" => ["example.com"]}
      }

      conv = conv!(agent("accept-edits", settings))
      assert :allow = check(conv, %{"url" => "https://docs.example.com/a"})
      assert {:block, _} = check(conv, %{"url" => "https://other.example/a"})
    end
  end

  describe "web_fetch" do
    test "returns markdown in the output and the three channels" do
      html =
        "<html><head><title>Doc</title></head><body><main><h1>Hi</h1><p>See <a href=\"/more\">more</a>.</p></main></body></html>"

      result = call(%{"url" => "https://example.com/start"}, page(html))

      refute result["is_error"]
      assert result["output"] =~ "Title: Doc\nURL: https://example.com/start\n"
      assert result["output"] =~ "# Hi"
      assert result["output"] =~ "[more](https://example.com/more)"

      assert %{
               "final_url" => "https://example.com/start",
               "status" => 200,
               "content_type" => "text/html" <> _,
               "title" => "Doc",
               "truncated" => false,
               "links" => ["https://example.com/more"],
               "artifact" => nil,
               "next_offset" => nil
             } = result["structured_output"]

      assert result["structured_output"]["bytes"] == byte_size(html)
      assert result["structured_output"]["chars"] > 0

      assert %{
               "redirects" => [%{"status" => 200}],
               "resolved_ip" => "93.184.216.34",
               "duration_ms" => ms,
               "cache_hit" => false
             } = result["details"]

      assert is_integer(ms)
    end

    test "text and raw formats" do
      html = "<main><h1>Hi</h1><p>a <b>b</b></p></main>"

      assert call(%{"url" => "https://example.com/", "format" => "text"}, page(html))["output"] =~
               "Hi\n\na b"

      assert call(%{"url" => "https://example.com/", "format" => "raw"}, page(html))["output"] =~
               html
    end

    test "pretty-prints JSON" do
      result = call(%{"url" => "https://example.com/api"}, page(~s({"a":1}), "application/json"))
      assert result["output"] =~ ~s({\n  "a": 1\n})
    end

    test "cuts at max_chars with a note naming the offset, and pages on" do
      text = String.duplicate("abcdefghij", 100)
      plug = page(text, "text/plain")

      first = call(%{"url" => "https://example.com/", "max_chars" => 250}, plug)
      assert first["output"] =~ "Call web_fetch again with offset=250"
      assert first["output"] =~ "of 1000"

      assert %{"truncated" => true, "next_offset" => 250, "chars" => 1000} =
               first["structured_output"]

      second = call(%{"url" => "https://example.com/", "max_chars" => 250, "offset" => 250}, plug)
      assert second["output"] =~ "offset=500"
      last = call(%{"url" => "https://example.com/", "max_chars" => 250, "offset" => 750}, plug)
      refute last["output"] =~ "Truncated"
      assert %{"truncated" => false, "next_offset" => nil} = last["structured_output"]
    end

    test "max_chars is clamped to 100,000 and defaults to 20,000" do
      plug = page(String.duplicate("a", 150_000), "text/plain")
      default = call(%{"url" => "https://example.com/"}, plug)
      assert default["structured_output"]["next_offset"] == 20_000
      huge = call(%{"url" => "https://example.com/", "max_chars" => 9_999_999}, plug)
      assert huge["structured_output"]["next_offset"] == 100_000
    end

    test "reports the redirect chain" do
      plug = fn conn ->
        case conn.request_path do
          "/a" ->
            conn |> Plug.Conn.put_resp_header("location", "/b") |> Plug.Conn.send_resp(301, "")

          "/b" ->
            conn
            |> Plug.Conn.put_resp_content_type("text/plain")
            |> Plug.Conn.send_resp(200, "arrived")
        end
      end

      result = call(%{"url" => "https://example.com/a"}, plug)
      assert result["output"] =~ "(redirected from https://example.com/a)"
      assert result["output"] =~ "arrived"
      assert Enum.map(result["details"]["redirects"], & &1["status"]) == [301, 200]
    end

    test "is_error with the reason for a 4xx, a 5xx, a policy refusal, a timeout and a failed lookup" do
      not_found =
        call(%{"url" => "https://example.com/x"}, fn conn ->
          Plug.Conn.send_resp(conn, 404, "")
        end)

      assert %{"is_error" => true, "output" => "HTTP 404 from https://example.com/x."} = not_found
      assert not_found["structured_output"]["status"] == 404

      assert %{"is_error" => true, "output" => "HTTP 503" <> _} =
               call(%{"url" => "https://example.com/"}, fn conn ->
                 Plug.Conn.send_resp(conn, 503, "")
               end)

      refused = call(%{"url" => "http://169.254.169.254/latest/meta-data/"}, never())
      assert %{"is_error" => true, "output" => "Refused: " <> _} = refused

      assert %{"is_error" => true, "output" => "Refused: " <> _} =
               call(%{"url" => "http://localhost/"}, never())

      slow = fn conn ->
        Process.sleep(3_000)
        Plug.Conn.send_resp(conn, 200, "")
      end

      assert %{"is_error" => true, "output" => "Timed out after 150 ms."} =
               call(%{"url" => "https://example.com/"}, slow, config: [fetch: [timeout_ms: 150]])

      conv = conv!()

      ctx = %{
        conversation_id: conv.id,
        config: [fetch: [resolver: fn _ -> {:error, :nxdomain} end]]
      }

      assert %{"is_error" => true, "output" => "The host name did not resolve" <> _} =
               Web.wrap_tool("web_fetch", %{"url" => "https://gone.example/"}, & &1, ctx)
    end

    test "a redirect to a private address is refused" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "http://127.0.0.1:80/secret")
        |> Plug.Conn.send_resp(302, "")
      end

      assert %{"is_error" => true, "output" => "Refused: " <> msg} =
               call(%{"url" => "https://example.com/"}, plug)

      assert msg =~ "reserved"
    end

    test "there is no headers argument: a call that sends one is refused before any request" do
      result =
        call(
          %{"url" => "https://example.com/", "headers" => %{"authorization" => "Bearer x"}},
          never()
        )

      assert result["is_error"]
      assert result["output"] =~ "no `headers` argument"
    end

    test "invalid arguments are errors, not crashes" do
      for args <- [
            %{},
            %{"url" => 5},
            %{"url" => ""},
            %{"url" => "https://example.com", "format" => "pdf"},
            %{"url" => "https://example.com", "artifact" => "../x"},
            "junk",
            nil
          ] do
        assert %{"is_error" => true} = call(args, never()), inspect(args)
      end
    end

    test "a PDF is refused with a message that names the artifact argument" do
      plug = page("%PDF-1.7 binary", "application/pdf")
      result = call(%{"url" => "https://example.com/paper.pdf"}, plug)
      assert result["is_error"]
      assert result["output"] =~ "`artifact`"
      assert result["output"] =~ "PDF"
    end

    test "another binary type is refused the same way" do
      result =
        call(%{"url" => "https://example.com/a.png"}, page(<<137, 80, 78, 71>>, "image/png"))

      assert result["is_error"]
      assert result["output"] =~ "`artifact`"
    end

    test "artifact saves the full text and returns a summary instead of the body" do
      conv = conv!()
      body = "<main><h1>Saved</h1><p>" <> String.duplicate("word ", 100) <> "</p></main>"

      result =
        call(%{"url" => "https://example.com/p", "artifact" => "notes/page.md"}, page(body),
          conv: conv
        )

      refute result["is_error"]
      assert result["output"] =~ "Saved"
      assert result["output"] =~ "artifact `notes/page.md`"
      refute result["output"] =~ "word word"
      assert %{"artifact" => "notes/page.md", "truncated" => false} = result["structured_output"]

      assert {:ok, %{data: data}} = Artifacts.get(conv.id, "notes/page.md")
      assert data =~ "# Saved"
      assert data =~ "word word"
    end

    test "artifact saves a PDF byte for byte" do
      conv = conv!()

      result =
        call(
          %{"url" => "https://example.com/paper.pdf", "artifact" => "papers/a.pdf"},
          page("%PDF-1.7 raw bytes", "application/pdf"),
          conv: conv
        )

      refute result["is_error"]
      assert result["structured_output"]["artifact"] == "papers/a.pdf"
      assert {:ok, %{data: "%PDF-1.7 raw bytes"}} = Artifacts.get(conv.id, "papers/a.pdf")
    end

    test "a text past the size threshold is also saved in full, and the note names it" do
      conv = conv!()
      body = String.duplicate("abcdefghij", 50)

      result =
        call(%{"url" => "https://big.example/doc", "max_chars" => 100}, page(body, "text/plain"),
          conv: conv,
          config: [auto_artifact_chars: 400]
        )

      assert %{"artifact" => "web/big.example-" <> _ = name, "truncated" => true} =
               result["structured_output"]

      assert result["output"] =~ "artifact `#{name}`"
      assert {:ok, %{data: ^body}} = Artifacts.get(conv.id, name)
    end

    test "a text under the threshold is not saved" do
      conv = conv!()

      result =
        call(%{"url" => "https://example.com/"}, page("short", "text/plain"),
          conv: conv,
          config: [auto_artifact_chars: 400]
        )

      assert result["structured_output"]["artifact"] == nil
      assert Artifacts.list(conv.id) == []
    end

    test "a gzip bomb cannot exhaust memory: the body stops at max_bytes and the output stays small" do
      bomb = :zlib.gzip(:binary.copy("a", 30 * 1024 * 1024))

      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "text/plain")
        |> Plug.Conn.put_resp_header("content-encoding", "gzip")
        |> Plug.Conn.send_resp(200, bomb)
      end

      result =
        call(%{"url" => "https://example.com/"}, plug, config: [fetch: [max_bytes: 50_000]])

      refute result["is_error"]
      assert result["structured_output"]["bytes"] == 50_000
      assert result["structured_output"]["truncated"] == true
      assert result["output"] =~ "cut at 50000 bytes"
      assert byte_size(result["output"]) < 25_000
    end

    test "the output is valid UTF-8 for hostile bytes" do
      result =
        call(
          %{"url" => "https://example.com/"},
          page(<<"<main>ok ", 0xFF, 0xC0, 0x80, "</main>">>)
        )

      assert String.valid?(result["output"])
      assert {:ok, _} = Jason.encode(result)
    end
  end

  describe "web_search" do
    defp search_ctx(extra \\ []) do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "web" => %{
              "results" => [
                %{"title" => "One", "url" => "https://one.example", "description" => "first"},
                %{"title" => "Two", "url" => "https://two.example", "description" => ""}
              ]
            }
          })
        )
      end

      %{
        conversation_id: nil,
        config: [search: {:brave, [api_key: "k", req_options: [plug: plug]] ++ extra}]
      }
    end

    test "lists the results in output and structured_output" do
      result =
        Web.wrap_tool(
          "web_search",
          %{"query" => "elixir"},
          fn _ -> flunk("next called") end,
          search_ctx()
        )

      refute result["is_error"]

      assert result["output"] ==
               "1. One\n   https://one.example\n   first\n\n2. Two\n   https://two.example"

      assert [%{"url" => "https://one.example"}, %{"url" => "https://two.example"}] =
               result["structured_output"]["results"]
    end

    test "limits max_results and rejects a bad query" do
      one = Web.wrap_tool("web_search", %{"query" => "x", "max_results" => 1}, & &1, search_ctx())
      assert length(one["structured_output"]["results"]) == 1

      assert %{"is_error" => true} =
               Web.wrap_tool("web_search", %{"query" => ""}, & &1, search_ctx())

      assert %{"is_error" => true} =
               Web.wrap_tool(
                 "web_search",
                 %{"query" => String.duplicate("q", 500)},
                 & &1,
                 search_ctx()
               )
    end

    test "a provider error is_error with the reason" do
      plug = fn conn -> Plug.Conn.send_resp(conn, 401, "") end

      ctx = %{
        conversation_id: nil,
        config: [search: {:brave, api_key: "bad", req_options: [plug: plug]}]
      }

      assert %{"is_error" => true, "output" => out} =
               Web.wrap_tool("web_search", %{"query" => "x"}, & &1, ctx)

      assert out =~ "401"
    end
  end
end
