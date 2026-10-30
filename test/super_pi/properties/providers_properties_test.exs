defmodule SuperPi.Properties.ProvidersTest do
  @moduledoc """
  Properties of provider resolution (`SuperPi.AI.Providers`).

  Four fake providers stand in for real ones. Each handles a model prefix, and a flag in the
  application environment says whether it is configured. Provider lists, flags and model names
  are random. The oracle is the stated rule: the first provider in the list that handles the
  model serves it, and it fails if that provider is not configured.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias SuperPi.AI.Providers

  defmodule Fake do
    defmacro __using__(opts) do
      quote bind_quoted: [id: opts[:id], prefix: opts[:prefix]] do
        @behaviour SuperPi.AI.Provider
        def id, do: unquote(id)
        def handles?(model), do: unquote(prefix) == "" or String.starts_with?(model, unquote(prefix))
        def configured?, do: Application.get_env(:super_pi, :"fake_configured_#{unquote(id)}", true)
        def models, do: [%{"id" => unquote(id) <> "-model", "label" => unquote(id)}]
        def generate(_payload, _opts), do: {:ok, %{"role" => "assistant", "content" => []}}
      end
    end
  end

  defmodule A do
    use Fake, id: "a", prefix: "a-"
  end

  defmodule B do
    use Fake, id: "b", prefix: "b-"
  end

  defmodule AB do
    use Fake, id: "ab", prefix: "a"
  end

  defmodule Any do
    use Fake, id: "any", prefix: ""
  end

  @fakes [A, B, AB, Any]

  setup do
    keys = [:mock_llm, :providers, :gemini_api_key] ++ Enum.map(@fakes, &:"fake_configured_#{&1.id()}")
    saved = Enum.map(keys, &{&1, Application.fetch_env(:super_pi, &1)})
    System.delete_env("GEMINI_API_KEY")

    on_exit(fn ->
      Enum.each(saved, fn
        {k, {:ok, v}} -> Application.put_env(:super_pi, k, v)
        {k, :error} -> Application.delete_env(:super_pi, k)
      end)
    end)

    Application.put_env(:super_pi, :mock_llm, false)
    :ok
  end

  defp provider_lists do
    @fakes |> member_of() |> list_of(max_length: 4) |> map(&Enum.uniq/1)
  end

  defp models do
    one_of([
      map({member_of(["a-", "b-", "a", "gemini-", "google/", "super-pi-", "claude-", "gpt-", ""]), string(:printable, max_length: 12)}, fn {p, r} -> p <> r end),
      string(:printable, max_length: 20),
      binary(max_length: 20)
    ])
  end

  defp configure(providers, flags) do
    Application.put_env(:super_pi, :providers, providers)

    for {mod, flag} <- Enum.zip(@fakes, flags) do
      Application.put_env(:super_pi, :"fake_configured_#{mod.id()}", flag)
    end
  end

  defp flags, do: list_of(boolean(), length: length(@fakes))

  property "the first provider that handles the model serves it, or the call fails" do
    check all(providers <- provider_lists(), flags <- flags(), model <- models(), max_runs: 300) do
      configure(providers, flags)

      case {Enum.find(providers, & &1.handles?(model)), Providers.resolve(model)} do
        {nil, result} ->
          assert result == {:error, {:no_provider, model}}

        {provider, {:ok, resolved, _}} ->
          assert resolved == provider
          assert provider.configured?()

        {provider, {:error, reason}} ->
          refute provider.configured?()
          assert reason == {:not_configured, provider.id()}
      end
    end
  end

  property "the result is never the mock provider when mock mode is off" do
    check all(providers <- provider_lists(), flags <- flags(), model <- models(), max_runs: 200) do
      configure(providers, flags)

      case Providers.resolve(model) do
        {:ok, provider, _} -> refute provider == SuperPi.AI.Providers.Mock
        {:error, _} -> :ok
      end
    end
  end

  property "resolve never raises, for any binary" do
    check all(model <- one_of([binary(), string(:printable), string(:utf8)]), max_runs: 300) do
      Application.put_env(:super_pi, :providers, [SuperPi.AI.Providers.Gemini])
      assert match?({:ok, _, _}, Providers.resolve(model)) or match?({:error, _}, Providers.resolve(model))
    end
  end

  property "a provider that is not configured never serves a request" do
    check all(providers <- provider_lists(), model <- models(), max_runs: 150) do
      configure(providers, [false, false, false, false])

      case Providers.resolve(model) do
        {:ok, _, _} -> flunk("an unconfigured provider served #{inspect(model)}")
        {:error, _} -> :ok
      end
    end
  end

  property "mock mode serves every model through the mock provider only" do
    check all(providers <- provider_lists(), model <- models(), max_runs: 100) do
      configure(providers, [true, true, true, true])
      Application.put_env(:super_pi, :mock_llm, true)
      assert {:ok, SuperPi.AI.Providers.Mock, _} = Providers.resolve(model)
      Application.put_env(:super_pi, :mock_llm, false)
    end
  end

  property "every catalog entry names one provider and reports that provider's availability" do
    check all(providers <- provider_lists(), flags <- flags(), max_runs: 100) do
      configure(providers, flags)
      catalog = Providers.catalog()

      assert length(catalog) == length(providers)

      for entry <- catalog do
        provider = Enum.find(providers, &(&1.id() == entry["provider"]))
        assert provider
        assert entry["available"] == provider.configured?()
      end
    end
  end
end
