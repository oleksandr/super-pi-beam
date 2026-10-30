defmodule SuperPi.Web.Search do
  @moduledoc """
  Search provider adapters for `web_search`.

  `web_search` is offered to the model only when a provider is configured and usable
  (`configured/1`). A tool that always fails costs tokens on every request and teaches the model
  to retry, so with no provider the tool does not exist. There is no fallback that scrapes a
  search engine.

  A provider is a module that implements this behaviour:

  | Provider | Module | Needs |
  |---|---|---|
  | Brave Search | `SuperPi.Web.Search.Brave` | `api_key` or `BRAVE_API_KEY` |
  | Tavily | `SuperPi.Web.Search.Tavily` | `api_key` or `TAVILY_API_KEY` |
  | SearxNG | `SuperPi.Web.Search.SearxNG` | `base_url` or `SEARXNG_URL` |

  ## Configuration

  The provider comes from the first of: the plugin option `search:`, `config :super_pi,
  :web_search`, the environment variable `SUPER_PI_WEB_SEARCH` (`brave`, `tavily` or `searxng`).
  A value is an atom or name (`:brave`), a module, or `{module_or_name, opts}`. Options are
  `api_key`, `base_url` and `req_options` (merged into the Req call, for tests).

  The endpoints are operator-configured and trusted, so they are not subject to
  `SuperPi.Web.Policy` (a SearxNG instance on a private network is the normal case). Result
  URLs are untrusted: the model still has to fetch them with `web_fetch`, which applies the policy.
  """

  @type result :: %{title: String.t(), url: String.t(), snippet: String.t()}

  @callback search(query :: String.t(), max_results :: pos_integer(), opts :: keyword()) :: {:ok, [result()]} | {:error, String.t()}
  @callback configured?(opts :: keyword()) :: boolean()

  @max_snippet 500

  @doc """
  Resolves the provider for a web plugin's options: `{module, opts}`, or `nil` when none is
  configured or the configured one lacks its key or URL.
  """
  @spec configured(keyword()) :: {module(), keyword()} | nil
  def configured(plugin_opts) when is_list(plugin_opts) do
    spec = Keyword.get(plugin_opts, :search) || Application.get_env(:super_pi, :web_search) || System.get_env("SUPER_PI_WEB_SEARCH")
    resolve(spec)
  end

  def configured(_), do: nil

  @doc "Resolves a provider spec. See the moduledoc for the accepted forms."
  @spec resolve(term()) :: {module(), keyword()} | nil
  def resolve({name, opts}) when is_list(opts) do
    with mod when not is_nil(mod) <- adapter(name), true <- usable?(mod, opts) do
      {mod, opts}
    else
      _ -> nil
    end
  end

  def resolve(name) when is_atom(name) or is_binary(name) do
    with mod when not is_nil(mod) <- adapter(name), true <- usable?(mod, []) do
      {mod, []}
    else
      _ -> nil
    end
  end

  def resolve(_), do: nil

  defp usable?(mod, opts) do
    Code.ensure_loaded?(mod) and function_exported?(mod, :search, 3) and function_exported?(mod, :configured?, 1) and mod.configured?(opts)
  end

  defp adapter(name) when is_binary(name) do
    case name |> String.trim() |> String.downcase() do
      "brave" -> SuperPi.Web.Search.Brave
      "tavily" -> SuperPi.Web.Search.Tavily
      "searxng" -> SuperPi.Web.Search.SearxNG
      _ -> nil
    end
  end

  defp adapter(nil), do: nil

  defp adapter(name) when is_atom(name) do
    case Atom.to_string(name) do
      "Elixir." <> _ -> name
      plain -> adapter(plain)
    end
  end

  defp adapter(_), do: nil

  @doc "Runs a search through a resolved provider. Never raises."
  @spec run({module(), keyword()}, String.t(), pos_integer()) :: {:ok, [result()]} | {:error, String.t()}
  def run({mod, opts}, query, max_results) do
    case mod.search(query, max_results, opts) do
      {:ok, results} when is_list(results) -> {:ok, Enum.take(results, max_results)}
      {:error, reason} -> {:error, to_string(reason)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc false
  # Shared by the adapters: Req options with the dedicated pool and no retries.
  def req_options(opts) do
    [finch: [name: SuperPi.WebFinch], retry: false, receive_timeout: 15_000] ++ Keyword.get(opts, :req_options, [])
  end

  @doc false
  def result(title, url, snippet) when is_binary(url) and url != "" do
    %{title: text(title), url: url, snippet: snippet |> text() |> String.slice(0, @max_snippet)}
  end

  def result(_title, _url, _snippet), do: nil

  @doc false
  def key(opts, env), do: Keyword.get(opts, :api_key) || System.get_env(env)

  @doc false
  def failed(%Req.Response{status: status}), do: {:error, "The search provider answered HTTP #{status}."}
  def failed(exception) when is_exception(exception), do: {:error, "The search request failed: #{Exception.message(exception)}"}

  defp text(value) when is_binary(value), do: value |> String.replace_invalid() |> String.replace(~r/<[^>]+>/, "") |> String.trim()
  defp text(_), do: ""
end
