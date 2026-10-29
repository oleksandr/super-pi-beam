defmodule SuperPi.AI.GeminiClientDefectsTest do
  @moduledoc """
  Regression tests that reproduce `SuperPi.AI.GeminiClient` defects found in the
  code review. Every test is expected to FAIL on the current code and pass once the
  matching finding is fixed.

  HTTP is intercepted through Req's global `:default_options` (a `plug:` function), so
  no network access happens. The original options and env vars are restored on exit.

  Run only these:  mix test --only known_bug
  Skip these:      mix test --exclude known_bug
  """
  use ExUnit.Case, async: false

  alias SuperPi.AI.GeminiClient

  @moduletag :known_bug

  setup do
    old_opts = Application.get_env(:req, :default_options)
    old_key = System.get_env("GEMINI_API_KEY")
    System.put_env("GEMINI_API_KEY", "test-key-abc123")

    on_exit(fn ->
      if old_opts, do: Application.put_env(:req, :default_options, old_opts), else: Application.delete_env(:req, :default_options)
      if old_key, do: System.put_env("GEMINI_API_KEY", old_key), else: System.delete_env("GEMINI_API_KEY")
    end)

    :ok
  end

  # Serves `chunks` as one SSE response and reports the request to the test process.
  defp stub(chunks, status \\ 200) do
    test = self()

    plug = fn conn ->
      send(test, {:request, conn})

      conn =
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_chunked(status)

      Enum.reduce(chunks, conn, fn c, acc ->
        {:ok, acc} = Plug.Conn.chunk(acc, c)
        acc
      end)
    end

    Application.put_env(:req, :default_options, plug: plug, retry: false)
  end

  defp sse(map), do: "data: " <> Jason.encode!(map) <> "\n\n"

  defp payload(extra \\ %{}) do
    Map.merge(%{model: "gemini-3-flash-preview", messages: [%{"role" => "user", "content" => "hi"}]}, extra)
  end

  describe "error and block responses on HTTP 200 (gemini_client.ex:77-104)" do
    test "an in-stream error object yields {:error, _}" do
      stub([sse(%{"error" => %{"code" => 500, "message" => "internal", "status" => "INTERNAL"}})])
      assert {:error, _} = GeminiClient.generate(payload())
    end

    test "a prompt blocked by safety (promptFeedback.blockReason only) yields {:error, _}" do
      stub([sse(%{"promptFeedback" => %{"blockReason" => "SAFETY"}})])
      assert {:error, _} = GeminiClient.generate(payload())
    end
  end

  describe "usage (gemini_client.ex:77-104)" do
    test "usageMetadata that arrives after the finishReason chunk is not lost" do
      stub([
        sse(%{"candidates" => [%{"content" => %{"parts" => [%{"text" => "hi"}]}, "finishReason" => "STOP"}]}),
        sse(%{"usageMetadata" => %{"promptTokenCount" => 11, "candidatesTokenCount" => 42}})
      ])

      assert {:ok, msg} = GeminiClient.generate(payload())
      assert msg["usage"]["output_tokens"] == 42, "stale usage: #{inspect(msg["usage"])}"
    end
  end

  describe "request construction (gemini_client.ex:47,315)" do
    test "the API key is sent in a header, not in the URL" do
      stub([sse(%{"candidates" => [%{"content" => %{"parts" => [%{"text" => "ok"}]}, "finishReason" => "STOP"}]})])
      GeminiClient.generate(payload())

      assert_received {:request, conn}
      refute conn.query_string =~ "key=", "API key leaked into the query string: #{conn.query_string}"
      assert Plug.Conn.get_req_header(conn, "x-goog-api-key") == ["test-key-abc123"]
    end

    for {label, model} <- [query_injection: "gemini-x?foo=bar", path_traversal: "gemini-../x", fragment: "gemini-x#frag"] do
      test "a client-supplied model name with #{label} cannot alter the request URL" do
        stub([sse(%{"candidates" => [%{"content" => %{"parts" => [%{"text" => "ok"}]}, "finishReason" => "STOP"}]})])
        GeminiClient.generate(payload(%{model: unquote(model)}))

        assert_received {:request, conn}
        refute conn.query_params["foo"], "model injected a query parameter"
        refute ".." in conn.path_info, "model injected a path traversal: #{inspect(conn.path_info)}"
        assert List.last(conn.path_info) =~ ":streamGenerateContent", "model truncated the URL: #{inspect(conn.path_info)}"
        assert length(conn.path_info) == 3, "model changed the path shape: #{inspect(conn.path_info)}"
      end
    end

    test "a nil model does not raise" do
      stub([sse(%{"candidates" => [%{"content" => %{"parts" => [%{"text" => "ok"}]}, "finishReason" => "STOP"}]})])
      result = try_generate(payload(%{model: nil}))
      refute match?({:raised, _}, result), "got #{inspect(result)}"
    end

    test "a non-string model does not raise" do
      stub([sse(%{"candidates" => [%{"content" => %{"parts" => [%{"text" => "ok"}]}, "finishReason" => "STOP"}]})])
      result = try_generate(payload(%{model: 123}))
      refute match?({:raised, _}, result), "got #{inspect(result)}"
    end
  end

  defp try_generate(p) do
    GeminiClient.generate(p)
  rescue
    e -> {:raised, e}
  end

  describe "history conversion (gemini_client.ex:202-214)" do
    defp call(id, name), do: %{"type" => "tool_call", "id" => id, "name" => name, "arguments" => %{}}

    defp history do
      [
        %{"role" => "user", "content" => "do two things"},
        %{"role" => "assistant", "content" => [call("c1", "read"), call("c2", "ls")]},
        %{"role" => "tool", "tool_call_id" => "c1", "name" => "read", "content" => "r1"},
        %{"role" => "tool", "tool_call_id" => "c2", "name" => "ls", "content" => "r2"}
      ]
    end

    test "consecutive tool results are grouped into one content with one functionResponse per call" do
      %{"contents" => contents} = GeminiClient.build_gemini_body(%{messages: history()})

      assert length(contents) == 3, "expected user, model, user(2 responses); got #{length(contents)} contents"
      last = List.last(contents)
      assert Enum.count(last["parts"], &Map.has_key?(&1, "functionResponse")) == 2
    end

    test "a tool message without a name still answers its functionCall" do
      msgs = List.replace_at(history(), 2, %{"role" => "tool", "tool_call_id" => "c1", "content" => "r1"})
      %{"contents" => contents} = GeminiClient.build_gemini_body(%{messages: msgs})

      calls = for c <- contents, p <- c["parts"], Map.has_key?(p, "functionCall"), do: p
      responses = for c <- contents, p <- c["parts"], Map.has_key?(p, "functionResponse"), do: p
      assert length(responses) == length(calls), "#{length(calls)} functionCalls but #{length(responses)} functionResponses (orphan call)"
    end

    test "a map tool output does not crash the conversion" do
      msgs = [%{"role" => "tool", "name" => "read", "content" => %{"lines" => [1, 2]}}]

      result =
        try do
          {:ok, GeminiClient.build_gemini_body(%{messages: msgs})}
        rescue
          e -> {:raised, e}
        end

      assert {:ok, _} = result
    end

    test "image blocks are not stringified with inspect/1" do
      msgs = [
        %{
          "role" => "user",
          "content" => [%{"type" => "image", "source" => %{"type" => "base64", "media_type" => "image/png", "data" => "BASE64DATA"}}]
        }
      ]

      %{"contents" => [%{"parts" => parts}]} = GeminiClient.build_gemini_body(%{messages: msgs})
      refute Enum.any?(parts, &(is_binary(&1["text"]) and &1["text"] =~ "BASE64DATA")), "image sent as inspect/1 text: #{inspect(parts)}"
    end
  end
end
