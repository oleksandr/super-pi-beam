defmodule SuperPi.Web.SearchTest do
  use ExUnit.Case, async: true

  alias SuperPi.Web.Search
  alias SuperPi.Web.Search.{Brave, SearxNG, Tavily}

  defp json(conn, status \\ 200, data),
    do:
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(data))

  describe "resolve/1 and configured/1" do
    test "a provider resolves only with its key or URL" do
      assert {Brave, [api_key: "k"]} = Search.resolve({:brave, api_key: "k"})
      assert {Tavily, [api_key: "k"]} = Search.resolve({"tavily", api_key: "k"})
      assert {SearxNG, [base_url: "http://x"]} = Search.resolve({SearxNG, base_url: "http://x"})
      assert Search.resolve({:brave, api_key: ""}) == nil
      assert Search.resolve({:searxng, []}) == nil || System.get_env("SEARXNG_URL") != nil
    end

    test "nothing, an unknown name and junk resolve to nil" do
      assert Search.resolve(nil) == nil
      assert Search.resolve(:duckduckgo) == nil
      assert Search.resolve("scrape-google") == nil
      assert Search.resolve(123) == nil
      assert Search.resolve({String, []}) == nil
    end

    test "configured/1 reads the plugin option first" do
      assert {Brave, _} = Search.configured(search: {:brave, api_key: "k"})
    end
  end

  describe "adapters" do
    test "Brave sends the token and maps results" do
      parent = self()

      plug = fn conn ->
        send(
          parent,
          {:req, conn.request_path, conn.query_string,
           Plug.Conn.get_req_header(conn, "x-subscription-token")}
        )

        json(conn, %{
          "web" => %{
            "results" => [
              %{
                "title" => "<b>Elixir</b>",
                "url" => "https://elixir-lang.org",
                "description" => "A language"
              },
              %{"title" => "no url"}
            ]
          }
        })
      end

      assert {:ok, [%{title: "Elixir", url: "https://elixir-lang.org", snippet: "A language"}]} =
               Brave.search("elixir lang", 3, api_key: "tok", req_options: [plug: plug])

      assert_receive {:req, "/res/v1/web/search", query, ["tok"]}
      assert query =~ "q=elixir+lang"
      assert query =~ "count=3"
    end

    test "Tavily posts the query with a bearer key" do
      parent = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:req, Jason.decode!(body), Plug.Conn.get_req_header(conn, "authorization")})

        json(conn, %{
          "results" => [%{"title" => "T", "url" => "https://t.example", "content" => "snippet"}]
        })
      end

      assert {:ok, [%{url: "https://t.example", snippet: "snippet"}]} =
               Tavily.search("q", 2, api_key: "k", req_options: [plug: plug])

      assert_receive {:req, %{"query" => "q", "max_results" => 2}, ["Bearer k"]}
    end

    test "SearxNG asks for JSON and trims to max_results" do
      parent = self()

      plug = fn conn ->
        send(parent, {:req, conn.request_path, conn.query_string})

        json(conn, %{
          "results" =>
            for(
              i <- 1..5,
              do: %{"title" => "t#{i}", "url" => "https://r#{i}.example", "content" => "c"}
            )
        })
      end

      assert {:ok, results} =
               SearxNG.search("q", 2,
                 base_url: "http://searx.internal:8080/",
                 req_options: [plug: plug]
               )

      assert length(results) == 2
      assert_receive {:req, "/search", query}
      assert query =~ "format=json"
    end

    test "an HTTP error or a transport error is an error tuple" do
      assert {:error, msg} =
               Brave.search("q", 1,
                 api_key: "k",
                 req_options: [plug: fn conn -> json(conn, 429, %{}) end]
               )

      assert msg =~ "429"

      assert {:error, _} =
               Brave.search("q", 1,
                 api_key: "k",
                 req_options: [plug: fn conn -> Req.Test.transport_error(conn, :econnrefused) end]
               )
    end

    test "a long snippet is cut" do
      plug = fn conn ->
        json(conn, %{
          "web" => %{
            "results" => [
              %{
                "title" => "t",
                "url" => "https://a.example",
                "description" => String.duplicate("x", 2000)
              }
            ]
          }
        })
      end

      assert {:ok, [%{snippet: snippet}]} =
               Brave.search("q", 1, api_key: "k", req_options: [plug: plug])

      assert String.length(snippet) == 500
    end

    test "run/3 never raises" do
      defmodule Exploding do
        @behaviour SuperPi.Web.Search
        def configured?(_), do: true
        def search(_, _, _), do: raise("boom")
      end

      assert {:error, "boom"} = Search.run({Exploding, []}, "q", 1)
    end
  end
end
