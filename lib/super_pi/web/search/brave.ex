defmodule SuperPi.Web.Search.Brave do
  @moduledoc """
  Brave Search adapter (`https://api.search.brave.com/res/v1/web/search`).

  Options: `api_key` (default `BRAVE_API_KEY`), `base_url`, `req_options`.
  """

  @behaviour SuperPi.Web.Search

  alias SuperPi.Web.Search

  @url "https://api.search.brave.com/res/v1/web/search"

  @impl true
  def configured?(opts), do: Search.key(opts, "BRAVE_API_KEY") not in [nil, ""]

  @impl true
  def search(query, max_results, opts) do
    req =
      [
        url: Keyword.get(opts, :base_url, @url),
        params: [q: query, count: max_results],
        headers: [{"accept", "application/json"}, {"x-subscription-token", Search.key(opts, "BRAVE_API_KEY")}]
      ] ++ Search.req_options(opts)

    case Req.get(req) do
      {:ok, %Req.Response{status: 200, body: %{} = body}} ->
        results = get_in(body, ["web", "results"]) || []
        {:ok, results |> Enum.map(&Search.result(&1["title"], &1["url"], &1["description"])) |> Enum.reject(&is_nil/1)}

      {:ok, resp} ->
        Search.failed(resp)

      {:error, exception} ->
        Search.failed(exception)
    end
  end
end
