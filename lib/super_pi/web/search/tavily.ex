defmodule SuperPi.Web.Search.Tavily do
  @moduledoc """
  Tavily adapter (`https://api.tavily.com/search`).

  Options: `api_key` (default `TAVILY_API_KEY`), `base_url`, `req_options`.
  """

  @behaviour SuperPi.Web.Search

  alias SuperPi.Web.Search

  @url "https://api.tavily.com/search"

  @impl true
  def configured?(opts), do: Search.key(opts, "TAVILY_API_KEY") not in [nil, ""]

  @impl true
  def search(query, max_results, opts) do
    req =
      [
        method: :post,
        url: Keyword.get(opts, :base_url, @url),
        json: %{query: query, max_results: max_results},
        headers: [{"authorization", "Bearer " <> Search.key(opts, "TAVILY_API_KEY")}]
      ] ++ Search.req_options(opts)

    case Req.request(req) do
      {:ok, %Req.Response{status: 200, body: %{} = body}} ->
        results = body["results"] || []

        {:ok,
         results
         |> Enum.map(&Search.result(&1["title"], &1["url"], &1["content"]))
         |> Enum.reject(&is_nil/1)}

      {:ok, resp} ->
        Search.failed(resp)

      {:error, exception} ->
        Search.failed(exception)
    end
  end
end
