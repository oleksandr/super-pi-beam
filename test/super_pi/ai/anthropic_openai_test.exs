defmodule SuperPi.AI.AnthropicOpenAITest do
  @moduledoc """
  The Anthropic and OpenAI providers against a local server that replays the documented stream
  formats. This checks what is sent (headers, body, message mapping) and how the stream is read
  (text, tool calls, usage, errors). It does not prove behavior against the live APIs; see
  `live_provider_test.exs`.
  """
  use ExUnit.Case, async: false

  alias SuperPi.AI.Providers.{Anthropic, OpenAI}
  alias SuperPi.TestSupport.MockLLM

  @keys [:anthropic_api_key, :anthropic_base_url, :anthropic_max_tokens, :openai_api_key, :openai_base_url, :openai_max_tokens, :ai_req_options]

  setup do
    saved = Enum.map(@keys, &{&1, Application.fetch_env(:super_pi, &1)})
    System.delete_env("ANTHROPIC_API_KEY")
    System.delete_env("OPENAI_API_KEY")

    on_exit(fn ->
      Enum.each(saved, fn
        {k, {:ok, v}} -> Application.put_env(:super_pi, k, v)
        {k, :error} -> Application.delete_env(:super_pi, k)
      end)
    end)

    :ok
  end

  defp serve(provider, script) do
    {url, agent} = MockLLM.start(script)

    case provider do
      :anthropic ->
        Application.put_env(:super_pi, :anthropic_api_key, "sk-ant-test")
        Application.put_env(:super_pi, :anthropic_base_url, url)

      :openai ->
        Application.put_env(:super_pi, :openai_api_key, "sk-test")
        Application.put_env(:super_pi, :openai_base_url, url <> "/v1")
    end

    agent
  end

  defp payload(extra \\ %{}) do
    Map.merge(
      %{
        model: "claude-sonnet-5-5",
        system_sections: [%{"id" => "core", "content" => "You are a test agent."}, %{"id" => "rules", "content" => "Be brief."}],
        messages: [%{"role" => "user", "content" => [%{"type" => "text", "text" => "hello"}]}],
        tools: [%{"name" => "read", "description" => "Read a file"}]
      },
      extra
    )
  end

  defp collect_deltas do
    me = self()
    {fn ev -> send(me, {:delta, ev}) end, fn -> drain([]) end}
  end

  defp drain(acc) do
    receive do
      {:delta, ev} -> drain([ev | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # --- Anthropic fixtures ---

  defp anthropic_text(text_parts, usage_in \\ 25, usage_out \\ 7) do
    [
      {"message_start", %{"type" => "message_start", "message" => %{"id" => "msg_1", "type" => "message", "role" => "assistant", "model" => "claude-sonnet-5-5", "content" => [], "usage" => %{"input_tokens" => usage_in, "output_tokens" => 1}}}},
      {"content_block_start", %{"type" => "content_block_start", "index" => 0, "content_block" => %{"type" => "text", "text" => ""}}}
    ] ++
      Enum.map(text_parts, &{"content_block_delta", %{"type" => "content_block_delta", "index" => 0, "delta" => %{"type" => "text_delta", "text" => &1}}}) ++
      [
        {"content_block_stop", %{"type" => "content_block_stop", "index" => 0}},
        {"message_delta", %{"type" => "message_delta", "delta" => %{"stop_reason" => "end_turn"}, "usage" => %{"output_tokens" => usage_out}}},
        {"message_stop", %{"type" => "message_stop"}}
      ]
  end

  defp anthropic_tool_use do
    [
      {"message_start", %{"type" => "message_start", "message" => %{"id" => "msg_2", "role" => "assistant", "content" => [], "usage" => %{"input_tokens" => 40, "output_tokens" => 1}}}},
      {"content_block_start", %{"type" => "content_block_start", "index" => 0, "content_block" => %{"type" => "text", "text" => ""}}},
      {"content_block_delta", %{"type" => "content_block_delta", "index" => 0, "delta" => %{"type" => "text_delta", "text" => "Let me look."}}},
      {"content_block_stop", %{"type" => "content_block_stop", "index" => 0}},
      {"content_block_start", %{"type" => "content_block_start", "index" => 1, "content_block" => %{"type" => "tool_use", "id" => "toolu_01", "name" => "read", "input" => %{}}}},
      {"content_block_delta", %{"type" => "content_block_delta", "index" => 1, "delta" => %{"type" => "input_json_delta", "partial_json" => "{\"path\":"}}},
      {"content_block_delta", %{"type" => "content_block_delta", "index" => 1, "delta" => %{"type" => "input_json_delta", "partial_json" => " \"mix.exs\"}"}}},
      {"content_block_stop", %{"type" => "content_block_stop", "index" => 1}},
      {"message_delta", %{"type" => "message_delta", "delta" => %{"stop_reason" => "tool_use"}, "usage" => %{"output_tokens" => 33}}},
      {"message_stop", %{"type" => "message_stop"}}
    ]
  end

  describe "Anthropic" do
    test "text: request shape, content and usage" do
      serve(:anthropic, [{200, MockLLM.sse(anthropic_text(["Hel", "lo ", "there"]))}])
      {on_delta, deltas} = collect_deltas()

      assert {:ok, msg} = Anthropic.generate(payload(), on_delta: on_delta)

      assert_receive {:llm_request, %{path: "/v1/messages", headers: headers, body: body}}
      assert headers["x-api-key"] == "sk-ant-test"
      assert headers["anthropic-version"] == "2023-06-01"
      assert body["model"] == "claude-sonnet-5-5"
      assert body["stream"] == true
      assert body["max_tokens"] == 8192
      assert body["system"] == "You are a test agent.\n\nBe brief."
      assert body["messages"] == [%{"role" => "user", "content" => [%{"type" => "text", "text" => "hello"}]}]
      assert [%{"name" => "read", "description" => "Read a file", "input_schema" => %{"type" => "object", "required" => ["path"]}}] = body["tools"]

      assert msg["role"] == "assistant"
      assert msg["provider"] == "anthropic"
      assert msg["content"] == [%{"type" => "text", "text" => "Hello there"}]
      assert msg["usage"]["input_tokens"] == 25
      assert msg["usage"]["output_tokens"] == 7

      text = for {:text_delta, %{delta: d}} <- deltas.(), do: d
      assert Enum.join(text) == "Hello there"
    end

    test "tool use: a tool_call block with id, name and parsed arguments" do
      serve(:anthropic, [{200, MockLLM.sse(anthropic_tool_use(), 11)}])
      {on_delta, deltas} = collect_deltas()
      assert {:ok, msg} = Anthropic.generate(payload(), on_delta: on_delta)

      assert [%{"type" => "text", "text" => "Let me look."}, %{"type" => "tool_call", "id" => "toolu_01", "name" => "read", "arguments" => %{"path" => "mix.exs"}}] = msg["content"]
      assert msg["stop_reason"] == "tool_use"
      assert Enum.any?(deltas.(), &match?({:toolcall_delta, %{name: "read"}}, &1))
    end

    test "history: tool results are merged into one user message, thinking is dropped, images are mapped" do
      serve(:anthropic, [{200, MockLLM.sse(anthropic_text(["ok"]))}])

      history = [
        %{"role" => "user", "content" => [%{"type" => "text", "text" => "look at these"}, %{"type" => "image", "source" => %{"media_type" => "image/jpeg", "data" => "QUJD"}}]},
        %{
          "role" => "assistant",
          "content" => [
            %{"type" => "thinking", "thinking" => "hmm", "signature" => "sig"},
            %{"type" => "text", "text" => "reading two files"},
            %{"type" => "tool_call", "id" => "toolu_a", "name" => "read", "arguments" => %{"path" => "a"}},
            %{"type" => "tool_call", "id" => "toolu_b", "name" => "read", "arguments" => %{"path" => "b"}}
          ]
        },
        %{"role" => "tool", "tool_call_id" => "toolu_a", "content" => "contents of a"},
        %{"role" => "tool", "tool_call_id" => "toolu_b", "content" => %{"lines" => 3}, "is_error" => true},
        %{"role" => "user", "content" => "now summarize"}
      ]

      assert {:ok, _} = Anthropic.generate(payload(%{messages: history}), [])
      assert_receive {:llm_request, %{body: %{"messages" => [first, assistant, results]}}}

      assert [%{"type" => "text"}, %{"type" => "image", "source" => %{"type" => "base64", "media_type" => "image/jpeg", "data" => "QUJD"}}] = first["content"]
      assert assistant["role"] == "assistant"
      refute Enum.any?(assistant["content"], &(&1["type"] == "thinking"))
      assert [%{"type" => "text"}, %{"type" => "tool_use", "id" => "toolu_a", "input" => %{"path" => "a"}}, %{"type" => "tool_use", "id" => "toolu_b"}] = assistant["content"]

      # Both results, then the user's next text, in one message, results first.
      assert results["role"] == "user"
      assert [%{"type" => "tool_result", "tool_use_id" => "toolu_a", "content" => "contents of a"}, %{"type" => "tool_result", "tool_use_id" => "toolu_b", "is_error" => true, "content" => ~s({"lines":3})}, %{"type" => "text", "text" => "now summarize"}] = results["content"]
    end

    test "empty messages are not sent" do
      serve(:anthropic, [{200, MockLLM.sse(anthropic_text(["ok"]))}])
      history = [%{"role" => "assistant", "content" => [%{"type" => "thinking", "thinking" => "x", "signature" => "s"}]}, %{"role" => "user", "content" => "   "}, %{"role" => "user", "content" => "real"}]
      assert {:ok, _} = Anthropic.generate(payload(%{messages: history}), [])
      assert_receive {:llm_request, %{body: %{"messages" => [%{"role" => "user", "content" => [%{"text" => "real"}]}]}}}
    end

    test "max_tokens, base URL and the anthropic/ prefix follow config" do
      serve(:anthropic, [{200, MockLLM.sse(anthropic_text(["ok"]))}])
      Application.put_env(:super_pi, :anthropic_max_tokens, 1234)
      assert {:ok, _} = Anthropic.generate(payload(%{model: "anthropic/claude-opus-5-5"}), [])
      assert_receive {:llm_request, %{body: %{"model" => "claude-opus-5-5", "max_tokens" => 1234}}}
    end

    test "a stream that arrives in tiny chunks gives the same message" do
      serve(:anthropic, [{200, MockLLM.sse(anthropic_text(["Hel", "lo"]), 3)}])
      assert {:ok, %{"content" => [%{"text" => "Hello"}]}} = Anthropic.generate(payload(), [])
    end

    test "error statuses" do
      serve(:anthropic, [
        {401, Jason.encode!(%{"type" => "error", "error" => %{"type" => "authentication_error", "message" => "invalid x-api-key"}})},
        {429, [{"retry-after", "7"}], "{}"},
        {429, "{}"},
        {400, Jason.encode!(%{"type" => "error", "error" => %{"type" => "invalid_request_error", "message" => "max_tokens: too large"}})},
        {500, "upstream exploded"}
      ])

      assert {:error, {:http_error, 401, "invalid x-api-key"}} = Anthropic.generate(payload(), [])
      assert {:retry_after, 7_000} = Anthropic.generate(payload(), [])
      assert {:retry_after, 2_000} = Anthropic.generate(payload(), [])
      assert {:error, {:http_error, 400, "max_tokens: too large"}} = Anthropic.generate(payload(), [])
      assert {:error, {:http_error, 500, "upstream exploded"}} = Anthropic.generate(payload(), [])
    end

    test "529 (overloaded) is a retry, like 429" do
      # Plug cannot send 529, so a custom adapter returns it.
      Application.put_env(:super_pi, :anthropic_api_key, "k")
      Application.put_env(:super_pi, :ai_req_options, adapter: fn req -> {req, Req.Response.new(status: 529, body: "")} end)
      assert {:retry_after, 2_000} = Anthropic.generate(payload(), [])
    end

    test "a huge retry-after is capped" do
      serve(:anthropic, [{429, [{"retry-after", "99999"}], "{}"}])
      assert {:retry_after, 60_000} = Anthropic.generate(payload(), [])
    end

    test "an overloaded error event in the stream is retried; another error event is an error" do
      serve(:anthropic, [
        {200, MockLLM.sse([{"error", %{"type" => "error", "error" => %{"type" => "overloaded_error", "message" => "Overloaded"}}}])},
        {200, MockLLM.sse([{"error", %{"type" => "error", "error" => %{"type" => "invalid_request_error", "message" => "Bad"}}}])}
      ])

      assert {:retry_after, 2_000} = Anthropic.generate(payload(), [])
      assert {:error, {:stream_error, _}} = Anthropic.generate(payload(), [])
    end

    test "a refused connection is an error, not a crash" do
      Application.put_env(:super_pi, :anthropic_api_key, "k")
      Application.put_env(:super_pi, :anthropic_base_url, "http://127.0.0.1:1")
      assert {:error, {:request_failed, _}} = Anthropic.generate(payload(), [])
    end

    test "no key is an error" do
      assert {:error, :missing_anthropic_api_key} = Anthropic.generate(payload(), [])
      refute Anthropic.configured?()
    end

    test "handles, models and normalization" do
      assert Anthropic.handles?("claude-sonnet-5-5") and Anthropic.handles?("anthropic/claude-x")
      refute Anthropic.handles?("gpt-5")
      assert "claude-sonnet-5-5" in Enum.map(Anthropic.models(), & &1["id"])
      Application.put_env(:super_pi, :anthropic_models, ["claude-custom"])
      on_exit(fn -> Application.delete_env(:super_pi, :anthropic_models) end)
      assert Enum.map(Anthropic.models(), & &1["id"]) == ["claude-custom"]
    end
  end

  # --- OpenAI fixtures ---

  defp openai_chunk(delta, extra \\ %{}), do: Map.merge(%{"id" => "chatcmpl-1", "object" => "chat.completion.chunk", "model" => "gpt-5", "choices" => [%{"index" => 0, "delta" => delta}]}, extra)

  defp openai_text(parts) do
    [openai_chunk(%{"role" => "assistant", "content" => ""})] ++
      Enum.map(parts, &openai_chunk(%{"content" => &1})) ++
      [
        %{"id" => "chatcmpl-1", "object" => "chat.completion.chunk", "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}]},
        %{"id" => "chatcmpl-1", "object" => "chat.completion.chunk", "choices" => [], "usage" => %{"prompt_tokens" => 21, "completion_tokens" => 6, "total_tokens" => 27}},
        :done
      ]
  end

  defp openai_tool_call do
    [
      openai_chunk(%{"role" => "assistant", "content" => nil, "tool_calls" => [%{"index" => 0, "id" => "call_9", "type" => "function", "function" => %{"name" => "read", "arguments" => ""}}]}),
      openai_chunk(%{"tool_calls" => [%{"index" => 0, "function" => %{"arguments" => "{\"path\":"}}]}),
      openai_chunk(%{"tool_calls" => [%{"index" => 0, "function" => %{"arguments" => " \"mix.exs\"}"}}]}),
      %{"id" => "chatcmpl-1", "object" => "chat.completion.chunk", "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "tool_calls"}]},
      %{"id" => "chatcmpl-1", "object" => "chat.completion.chunk", "choices" => [], "usage" => %{"prompt_tokens" => 50, "completion_tokens" => 14, "total_tokens" => 64}},
      :done
    ]
  end

  describe "OpenAI" do
    test "text: request shape, content and usage" do
      serve(:openai, [{200, MockLLM.sse(openai_text(["Hel", "lo ", "there"]))}])
      {on_delta, deltas} = collect_deltas()

      assert {:ok, msg} = OpenAI.generate(payload(%{model: "gpt-5"}), on_delta: on_delta)

      assert_receive {:llm_request, %{path: "/v1/chat/completions", headers: headers, body: body}}
      assert headers["authorization"] == "Bearer sk-test"
      assert body["model"] == "gpt-5"
      assert body["stream"] == true
      assert body["stream_options"] == %{"include_usage" => true}
      assert [%{"role" => "system", "content" => "You are a test agent.\n\nBe brief."}, %{"role" => "user", "content" => "hello"}] = body["messages"]
      assert [%{"type" => "function", "function" => %{"name" => "read", "description" => "Read a file", "parameters" => %{"type" => "object"}}}] = body["tools"]
      refute Map.has_key?(body, "max_completion_tokens")

      assert msg["provider"] == "openai"
      assert msg["content"] == [%{"type" => "text", "text" => "Hello there"}]
      assert msg["usage"]["input_tokens"] == 21
      assert msg["usage"]["output_tokens"] == 6
      assert for({:text_delta, %{delta: d}} <- deltas.(), do: d) |> Enum.join() == "Hello there"
    end

    test "tool call: id, name and parsed arguments" do
      serve(:openai, [{200, MockLLM.sse(openai_tool_call())}])
      assert {:ok, msg} = OpenAI.generate(payload(%{model: "gpt-5"}), [])
      assert [%{"type" => "tool_call", "id" => "call_9", "name" => "read", "arguments" => %{"path" => "mix.exs"}}] = msg["content"]
      assert msg["stop_reason"] == "tool_calls"
      assert msg["usage"]["input_tokens"] == 50
    end

    test "history: tool_calls, tool messages, images and no thinking" do
      serve(:openai, [{200, MockLLM.sse(openai_text(["ok"]))}])

      history = [
        %{"role" => "user", "content" => [%{"type" => "text", "text" => "see"}, %{"type" => "image", "source" => %{"media_type" => "image/png", "data" => "QUJD"}}]},
        %{"role" => "assistant", "content" => [%{"type" => "thinking", "thinking" => "x", "signature" => "s"}, %{"type" => "tool_call", "id" => "call_1", "name" => "read", "arguments" => %{"path" => "a"}}]},
        %{"role" => "tool", "tool_call_id" => "call_1", "content" => "file a"},
        %{"role" => "assistant", "content" => [%{"type" => "text", "text" => "done"}]}
      ]

      assert {:ok, _} = OpenAI.generate(payload(%{model: "gpt-5", messages: history, system_sections: []}), [])
      assert_receive {:llm_request, %{body: %{"messages" => [user, assistant_calls, tool, assistant_text]}}}

      assert [%{"type" => "text", "text" => "see"}, %{"type" => "image_url", "image_url" => %{"url" => "data:image/png;base64,QUJD"}}] = user["content"]
      assert %{"role" => "assistant", "content" => nil, "tool_calls" => [%{"id" => "call_1", "type" => "function", "function" => %{"name" => "read", "arguments" => ~s({"path":"a"})}}]} = assistant_calls
      assert tool == %{"role" => "tool", "tool_call_id" => "call_1", "content" => "file a"}
      assert assistant_text == %{"role" => "assistant", "content" => "done"}
    end

    test "max tokens and json schema" do
      serve(:openai, [{200, MockLLM.sse(openai_text(["{}"]))}])
      Application.put_env(:super_pi, :openai_max_tokens, 500)
      assert {:ok, _} = OpenAI.generate(payload(%{model: "gpt-5", json_schema: %{"type" => "object"}}), [])
      assert_receive {:llm_request, %{body: body}}
      assert body["max_completion_tokens"] == 500
      assert body["response_format"] == %{"type" => "json_schema", "json_schema" => %{"name" => "response", "schema" => %{"type" => "object"}}}
    end

    test "tiny chunks give the same message" do
      serve(:openai, [{200, MockLLM.sse(openai_text(["Hel", "lo"]), 5)}])
      assert {:ok, %{"content" => [%{"text" => "Hello"}], "usage" => %{"input_tokens" => 21}}} = OpenAI.generate(payload(%{model: "gpt-5"}), [])
    end

    test "error statuses" do
      serve(:openai, [
        {401, Jason.encode!(%{"error" => %{"message" => "Incorrect API key provided", "type" => "invalid_request_error", "code" => "invalid_api_key"}})},
        {429, [{"retry-after", "3"}], Jason.encode!(%{"error" => %{"message" => "Rate limit"}})},
        {404, Jason.encode!(%{"error" => %{"message" => "The model `gpt-9` does not exist"}})},
        {503, "bad gateway"}
      ])

      assert {:error, {:http_error, 401, "Incorrect API key provided"}} = OpenAI.generate(payload(%{model: "gpt-5"}), [])
      assert {:retry_after, 3_000} = OpenAI.generate(payload(%{model: "gpt-5"}), [])
      assert {:error, {:http_error, 404, "The model `gpt-9` does not exist"}} = OpenAI.generate(payload(%{model: "gpt-9"}), [])
      assert {:error, {:http_error, 503, "bad gateway"}} = OpenAI.generate(payload(%{model: "gpt-5"}), [])
    end

    test "no key is an error; handles and models" do
      assert {:error, :missing_openai_api_key} = OpenAI.generate(payload(%{model: "gpt-5"}), [])
      assert OpenAI.handles?("gpt-5") and OpenAI.handles?("o3-mini") and OpenAI.handles?("openai/gpt-5") and OpenAI.handles?("o4-mini")
      refute OpenAI.handles?("claude-x")
      refute OpenAI.handles?("ollama-llama")
      assert "gpt-5" in Enum.map(OpenAI.models(), & &1["id"])
    end
  end

  describe "truncated streams and in-stream errors (Kanban Tasks 51 and 56)" do
    test "an Anthropic stream cut in the middle of a tool call is retried and never returns the call" do
      cut = anthropic_tool_use() |> Enum.take(6)
      serve(:anthropic, [{200, MockLLM.sse(cut)}])
      assert {:retry_after, 2_000} = Anthropic.generate(payload(), [])
    end

    test "an Anthropic stream with all its blocks but no message_stop is retried" do
      serve(:anthropic, [{200, MockLLM.sse(Enum.drop(anthropic_text(["Hel", "lo"]), -1))}])
      assert {:retry_after, 2_000} = Anthropic.generate(payload(), [])
    end

    test "tool arguments that are not valid JSON at message_stop are retried, not run" do
      events =
        Enum.map(anthropic_tool_use(), fn
          {"content_block_delta", %{"index" => 1, "delta" => %{"partial_json" => " \"mix.exs\"}"}} = ev} ->
            {"content_block_delta", put_in(ev, ["delta", "partial_json"], " \"mix.exs\"")}

          other ->
            other
        end)

      serve(:anthropic, [{200, MockLLM.sse(events)}])
      assert {:retry_after, 2_000} = Anthropic.generate(payload(), [])
    end

    test "an OpenAI stream without [DONE] is retried" do
      serve(:openai, [{200, MockLLM.sse(Enum.take(openai_tool_call(), 2))}])
      assert {:retry_after, 2_000} = OpenAI.generate(payload(%{model: "gpt-5"}), [])
    end

    test "an OpenAI error inside a 200 stream: server errors are retried, others are errors" do
      serve(:openai, [
        {200, MockLLM.sse([openai_chunk(%{"content" => "Hi"}), %{"error" => %{"message" => "The server had an error", "type" => "server_error"}}])},
        {200, MockLLM.sse([%{"error" => %{"message" => "Invalid", "type" => "invalid_request_error"}}])}
      ])

      assert {:retry_after, 2_000} = OpenAI.generate(payload(%{model: "gpt-5"}), [])
      assert {:error, {:stream_error, _}} = OpenAI.generate(payload(%{model: "gpt-5"}), [])
    end

    test "a tool call with no arguments at all has empty arguments" do
      events =
        anthropic_tool_use()
        |> Enum.reject(&match?({"content_block_delta", %{"index" => 1}}, &1))

      serve(:anthropic, [{200, MockLLM.sse(events)}])
      assert {:ok, %{"content" => [_text, %{"type" => "tool_call", "arguments" => %{}}]}} = Anthropic.generate(payload(), [])
    end
  end

  describe "tool schemas" do
    test "every built-in tool has a valid object schema, with the argument names the tools read" do
      for tool <- ~w(read write edit bash grep find ls tool_search) do
        schema = SuperPi.AI.ToolSchemas.for_tool(tool)
        assert schema["type"] == "object"
        assert is_map(schema["properties"])
        for required <- Map.get(schema, "required", []), do: assert(Map.has_key?(schema["properties"], required))
      end

      assert SuperPi.AI.ToolSchemas.for_tool("edit")["required"] == ["path", "old_text", "new_text"]
      assert SuperPi.AI.ToolSchemas.for_tool("unknown") == %{"type" => "object", "properties" => %{}}
    end
  end
end
