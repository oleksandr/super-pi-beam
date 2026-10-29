defmodule SuperPi.Gateway.GatewayDefectsTest do
  @moduledoc """
  Regression tests that reproduce gateway defects found in the code review
  (see vault note "20 - Codebase Review Findings"). Every test is expected to
  FAIL on the current code and pass once the matching finding is fixed.

  Run only these:  mix test --only known_bug
  Skip these:      mix test --exclude known_bug
  """
  use SuperPi.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias SuperPi.Gateway.Router
  alias SuperPi.Durable.Schemas.Conversation

  @opts Router.init([])


  setup do
    SuperPi.Tools.ensure_catalog_ets!()
    Router.ensure_session_cache!()
    :ok
  end

  defp post(body, headers \\ []) do
    raw = if is_binary(body), do: body, else: Jason.encode!(body)

    conn =
      conn(:post, "/v1/chat/completions", raw)
      |> put_req_header("content-type", "application/json")

    headers
    |> Enum.reduce(conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    |> Router.call(@opts)
  rescue
    e -> {:raised, e}
  end

  defp assert_openai_error(result, label) do
    case result do
      {:raised, e} ->
        flunk("#{label}: router raised #{inspect(e.__struct__)} instead of returning an error response")

      %Plug.Conn{status: status, resp_body: body} ->
        assert status in 400..499, "#{label}: expected a 4xx status, got #{status}"
        assert %{"error" => %{"message" => _}} = Jason.decode!(body), "#{label}: body is not an OpenAI error object"
    end
  end

  describe "malformed requests return OpenAI-style 400 errors (router.ex:60-74,340-381)" do
    test "messages is null" do
      assert_openai_error(post(%{"model" => "super-pi-fast", "messages" => nil}), "messages: null")
    end

    test "messages is not a list" do
      assert_openai_error(post(%{"model" => "super-pi-fast", "messages" => "hello"}), "messages: string")
    end

    test "a message entry is not an object" do
      assert_openai_error(post(%{"model" => "super-pi-fast", "messages" => ["hello"]}), "messages: [string]")
    end

    test "model is null" do
      body = %{"model" => nil, "messages" => [%{"role" => "user", "content" => "hi"}]}
      assert_openai_error(post(body), "model: null")
    end

    test "body is not valid JSON" do
      assert_openai_error(post("{not json"), "invalid JSON")
    end
  end

  describe "stream flag (router.ex:63)" do
    test "the string \"false\" does not select streaming" do
      body = %{"model" => "super-pi-fast", "stream" => "false", "messages" => [%{"role" => "user", "content" => "hi"}]}

      conn = post(body)
      assert %Plug.Conn{} = conn, "router raised: #{inspect(conn)}"

      content_type = conn |> get_resp_header("content-type") |> List.first() |> to_string()
      refute content_type =~ "event-stream", "a non-boolean stream value selected SSE"
    end
  end

  describe "conversation ownership (router.ex:286-338)" do
    test "x-conversation-id cannot attach a client to a conversation it did not create" do
      other = SuperPi.Durable.Storage.create_conversation!()

      body = %{"model" => "super-pi-fast", "messages" => [%{"role" => "user", "content" => "write into your conversation"}]}
      conn = post(body, [{"x-conversation-id", Integer.to_string(other.id)}, {"x-session-id", "attacker-#{System.unique_integer([:positive])}"}])
      assert %Plug.Conn{} = conn

      entries =
        Repo.all(from e in SuperPi.Durable.Schemas.Entry, where: e.conversation_id == ^other.id)

      refute Enum.any?(entries, fn e -> inspect(e.data) =~ "write into your conversation" end),
             "an unauthenticated client appended to an existing conversation"
    end

    test "two concurrent first requests with the same new session id create one conversation" do
      session = "race-#{System.unique_integer([:positive])}"
      before_count = Repo.one(from c in Conversation, select: count(c.id))

      resolve = fn ->
        # Router.resolve_conversation/2 is private; drive it through the public route.
        body = %{"model" => "super-pi-fast", "messages" => [%{"role" => "user", "content" => "hi"}]}
        post(body, [{"x-session-id", session}])
      end

      tasks = for _ <- 1..2, do: Task.async(resolve)
      Enum.each(tasks, &Task.await(&1, 10_000))

      created = Repo.one(from c in Conversation, select: count(c.id)) - before_count
      assert created == 1, "#{created} conversations created for one session id"
    end
  end

  describe "missing provider key (machine.ex:653-740 reached through the gateway)" do
    setup do
      keys = ["GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_GENERATIVE_AI_API_KEY"]
      saved_env = Map.new(keys, &{&1, System.get_env(&1)})
      saved_mock = Application.get_env(:super_pi, :mock_llm)

      Enum.each(keys, &System.delete_env/1)
      Application.put_env(:super_pi, :mock_llm, false)

      on_exit(fn ->
        Enum.each(saved_env, fn
          {k, nil} -> System.delete_env(k)
          {k, v} -> System.put_env(k, v)
        end)

        if saved_mock == nil,
          do: Application.delete_env(:super_pi, :mock_llm),
          else: Application.put_env(:super_pi, :mock_llm, saved_mock)
      end)

      :ok
    end

    test "a gemini model without an API key returns an error, not a fake 'Echo:' answer" do
      body = %{"model" => "gemini-2.5-flash", "messages" => [%{"role" => "user", "content" => "hello"}]}

      conn = post(body, [{"x-session-id", "nokey-#{System.unique_integer([:positive])}"}])
      assert %Plug.Conn{} = conn, "router raised: #{inspect(conn)}"

      refute conn.status == 200 and conn.resp_body =~ "Echo:",
             "the offline mock answered with a 200 and fabricated usage"
    end
  end
end
