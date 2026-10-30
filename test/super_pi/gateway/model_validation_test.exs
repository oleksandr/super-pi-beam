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
    conn = chat("claude-sonnet-5-5")
    assert conn.status == 404
    assert %{"code" => "model_not_found", "message" => message} = error_of(conn)
    assert message =~ "claude-sonnet-5-5"
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
end
