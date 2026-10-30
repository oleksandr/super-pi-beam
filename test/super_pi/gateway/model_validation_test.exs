defmodule SuperPi.Gateway.ModelValidationTest do
  @moduledoc """
  The gateway accepts a harness id or a model that a registered provider serves.
  Anything else is a client error before any conversation exists.
  """
  use SuperPi.DataCase, async: false
  import Plug.Test
  import Plug.Conn

  alias SuperPi.Gateway.Router

  @opts Router.init([])

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

  defp chat(model, headers \\ []) do
    body = %{"model" => model, "messages" => [%{"role" => "user", "content" => "hi"}]}
    sid = "mv-#{System.unique_integer([:positive])}"

    conn(:post, "/v1/chat/completions", Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-session-id", sid)
    |> then(fn c -> Enum.reduce(headers, c, fn {k, v}, acc -> put_req_header(acc, k, v) end) end)
    |> Router.call(@opts)
  end

  defp error_of(conn), do: Jason.decode!(conn.resp_body)["error"]

  test "a model that no provider serves is 404 model_not_found" do
    conn = chat("llama-3-70b")
    assert conn.status == 404
    assert %{"code" => "model_not_found", "message" => message} = error_of(conn)
    assert message =~ "llama-3-70b"
  end

  test "a claude model without a key is 503 provider_not_configured" do
    System.delete_env("ANTHROPIC_API_KEY")
    conn = chat("claude-sonnet-5-5")
    assert conn.status == 503
    assert %{"code" => "provider_not_configured", "message" => message} = error_of(conn)
    assert message =~ "anthropic"
  end

  test "a typo in a harness id is 404, not a run on the default harness" do
    assert chat("super-pi-plannr").status == 404
  end

  test "a model whose provider is not configured is 503 provider_not_configured" do
    conn = chat("gemini-3-flash-preview")
    assert conn.status == 503
    assert %{"code" => "provider_not_configured"} = error_of(conn)
  end

  test "an unknown model creates no conversation" do
    before = SuperPi.Durable.Storage.latest_conversation()
    assert chat("no-such-model").status == 404
    assert SuperPi.Durable.Storage.latest_conversation() == before
  end

  test "a harness id is accepted even with no provider key (the turn reports its own error)" do
    refute chat("super-pi-workspace").status == 404
  end

  test "a model that a registered provider serves passes validation" do
    defmodule Acme do
      @behaviour SuperPi.AI.Provider
      def id, do: "acme"
      def handles?(model), do: String.starts_with?(model, "acme-")
      def configured?, do: true
      def models, do: []
      def generate(_payload, _opts), do: {:ok, %{"role" => "assistant", "content" => [%{"type" => "text", "text" => "from acme"}]}}
    end

    Application.put_env(:super_pi, :providers, [Acme])
    conn = chat("acme-1")
    assert conn.status == 200
    assert conn.resp_body =~ "from acme"
  end

  describe "GET /v1/models" do
    defp models do
      conn(:get, "/v1/models") |> Router.call(@opts) |> then(&Jason.decode!(&1.resp_body)["data"])
    end

    test "lists harness ids, and provider models only when the provider is configured" do
      ids = models() |> Enum.map(& &1["id"])
      assert "super-pi-workspace" in ids
      refute "gemini-3-flash-preview" in ids

      Application.put_env(:super_pi, :gemini_api_key, "test-key")
      entry = Enum.find(models(), &(&1["id"] == "gemini-3-flash-preview"))
      assert entry["owned_by"] == "gemini"
    end

    test "every listed model is accepted by chat completions validation" do
      Application.put_env(:super_pi, :gemini_api_key, "test-key")
      Application.put_env(:super_pi, :mock_llm, true)

      # Listed harnesses run a real turn. Some commit their workspace when the turn ends
      # (AutoCommit), so run in a scratch directory and never in the repository.
      scratch = Path.join(System.tmp_dir!(), "mv_scratch_#{System.unique_integer([:positive])}")
      File.mkdir_p!(scratch)
      original = File.cwd!()
      File.cd!(scratch)

      on_exit(fn ->
        File.cd!(original)
        File.rm_rf(scratch)
      end)

      for %{"id" => id} <- models() do
        refute chat(id).status in [404, 503], "#{id} is listed but rejected"
      end
    end
  end
end
