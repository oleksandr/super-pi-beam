defmodule SuperPi.AI.ProvidersTest do
  use ExUnit.Case, async: false

  alias SuperPi.AI.Providers

  defmodule Custom do
    @behaviour SuperPi.AI.Provider

    def id, do: "custom"
    def handles?(model), do: String.starts_with?(model, "acme-")
    def configured?, do: true
    def models, do: [%{"id" => "acme-1", "label" => "Acme 1"}]
    def generate(_payload, _opts), do: {:ok, %{"role" => "assistant", "content" => []}}
  end

  setup do
    keys = [:mock_llm, :providers, :gemini_api_key]
    saved = Enum.map(keys, &{&1, Application.fetch_env(:super_pi, &1)})
    System.delete_env("GEMINI_API_KEY")

    on_exit(fn ->
      Enum.each(saved, fn
        {k, {:ok, v}} -> Application.put_env(:super_pi, k, v)
        {k, :error} -> Application.delete_env(:super_pi, k)
      end)
    end)

    Application.put_env(:super_pi, :mock_llm, false)
    Application.delete_env(:super_pi, :providers)
    Application.delete_env(:super_pi, :gemini_api_key)
    :ok
  end

  describe "resolve/1 fails closed" do
    test "a model without a provider is an error, not an echo" do
      assert {:error, {:no_provider, "llama-3-70b"}} = Providers.resolve("llama-3-70b")
      assert {:error, {:no_provider, "mistral-large"}} = Providers.resolve("mistral-large")
    end

    test "claude and gpt models have a provider, which is not configured without a key" do
      System.delete_env("ANTHROPIC_API_KEY")
      System.delete_env("OPENAI_API_KEY")
      assert {:error, {:not_configured, "anthropic"}} = Providers.resolve("claude-sonnet-5-5")
      assert {:error, {:not_configured, "openai"}} = Providers.resolve("gpt-5")
    end

    test "a configured key makes them resolvable" do
      Application.put_env(:super_pi, :anthropic_api_key, "k")
      Application.put_env(:super_pi, :openai_api_key, "k")
      on_exit(fn -> Application.delete_env(:super_pi, :anthropic_api_key) && Application.delete_env(:super_pi, :openai_api_key) end)

      assert {:ok, SuperPi.AI.Providers.Anthropic, "claude-sonnet-5-5"} = Providers.resolve("claude-sonnet-5-5")
      assert {:ok, SuperPi.AI.Providers.Anthropic, "claude-opus-5-5"} = Providers.resolve("anthropic/claude-opus-5-5")
      assert {:ok, SuperPi.AI.Providers.OpenAI, "gpt-5"} = Providers.resolve("openai/gpt-5")
      assert {:ok, SuperPi.AI.Providers.OpenAI, "o3-mini"} = Providers.resolve("o3-mini")
    end

    test "a Gemini model without a key is an error" do
      assert {:error, {:not_configured, "gemini"}} = Providers.resolve("gemini-3-flash-preview")
    end

    test "error messages name the model or provider" do
      assert Providers.format_error({:no_provider, "gpt-5"}) =~ "gpt-5"
      assert Providers.format_error({:not_configured, "gemini"}) =~ "gemini"
    end
  end

  describe "resolve/1 with a configured Gemini key" do
    setup do
      Application.put_env(:super_pi, :gemini_api_key, "test-key")
    end

    test "maps harness aliases and prefixes to Gemini models" do
      assert {:ok, SuperPi.AI.Providers.Gemini, "gemini-3-flash-preview"} = Providers.resolve("super-pi-fast")
      assert {:ok, _, "gemini-3.1-pro-preview"} = Providers.resolve("super-pi-planner")
      assert {:ok, _, "gemini-3-flash-preview"} = Providers.resolve("google/gemini-3-flash-preview")
    end

    test "still rejects models that no provider handles" do
      assert {:error, {:no_provider, "llama-x"}} = Providers.resolve("llama-x")
    end
  end

  describe "custom providers (escape hatch)" do
    test "a registered provider serves its models" do
      Application.put_env(:super_pi, :providers, [Custom, SuperPi.AI.Providers.Gemini])
      assert {:ok, Custom, "acme-1"} = Providers.resolve("acme-1")
    end

    test "providers earlier in the list win" do
      defmodule Greedy do
        def id, do: "greedy"
        def handles?(_), do: true
        def configured?, do: true
        def models, do: []
        def generate(_, _), do: {:ok, %{}}
      end

      Application.put_env(:super_pi, :providers, [Greedy, Custom])
      assert {:ok, Greedy, _} = Providers.resolve("acme-1")
    end

    test "the catalog lists registered providers with availability" do
      Application.put_env(:super_pi, :providers, [Custom, SuperPi.AI.Providers.Gemini])
      catalog = Providers.catalog()

      assert %{"provider" => "custom", "available" => true} = Enum.find(catalog, &(&1["id"] == "acme-1"))
      assert %{"available" => false} = Enum.find(catalog, &(&1["id"] == "gemini-3-flash-preview"))
      refute Enum.any?(catalog, &String.starts_with?(&1["id"], "claude-"))  # Anthropic is not in this list
    end
  end

  describe "mock mode" do
    test "serves every model through the mock provider only when enabled" do
      Application.put_env(:super_pi, :mock_llm, true)
      assert {:ok, SuperPi.AI.Providers.Mock, "claude-sonnet-5-5"} = Providers.resolve("claude-sonnet-5-5")

      {:ok, msg} =
        SuperPi.AI.Providers.Mock.generate(%{messages: [%{"role" => "user", "content" => "hi"}]}, [])

      assert [%{"text" => "Echo: hi"}] = msg["content"]
    end
  end
end
