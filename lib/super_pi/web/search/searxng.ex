defmodule SuperPi.Web.Search.SearxNG do
  @moduledoc """
  SearxNG adapter. Needs an instance with the JSON format enabled (`search.formats` includes
  `json` in its `settings.yml`).

  Options: `base_url` (default `SEARXNG_URL`, for example `https://searx.example.org`),
  `req_options`. The instance is operator-configured, so it may be on a private network.
  """

  @behaviour SuperPi.Web.Search

  alias SuperPi.Web.Search

  @impl true
  def configured?(opts), do: base_url(opts) not in [nil, ""]

  @impl true
  def search(query, max_results, opts) do
    req =
      [
        url: String.trim_trailing(base_url(opts), "/") <> "/search",
        params: [q: query, format: "json"]
      ] ++ Search.req_options(opts)

    case Req.get(req) do
      {:ok, %Req.Response{status: 200, body: %{} = body}} ->
        results = body["results"] || []

        {:ok,
         results
         |> Enum.map(&Search.result(&1["title"], &1["url"], &1["content"]))
         |> Enum.reject(&is_nil/1)
         |> Enum.take(max_results)}

      {:ok, resp} ->
        Search.failed(resp)

      {:error, exception} ->
        Search.failed(exception)
    end
  end

  defp base_url(opts), do: Keyword.get(opts, :base_url) || System.get_env("SEARXNG_URL")
end
