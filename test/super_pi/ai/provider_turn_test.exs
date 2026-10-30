defmodule SuperPi.AI.ProviderTurnTest do
  @moduledoc """
  A whole conversation turn through the Anthropic and OpenAI providers: the model asks for a tool,
  the machine runs it, and the second request carries the result. The server is local and replays
  the documented stream formats.
  """
  use SuperPi.DataCase, async: false

  alias SuperPi.Conversation.Machine
  alias SuperPi.Durable.Storage
  alias SuperPi.TestSupport.MockLLM

  @keys [:mock_llm, :anthropic_api_key, :anthropic_base_url, :openai_api_key, :openai_base_url]

  setup do
    saved = Enum.map(@keys, &{&1, Application.fetch_env(:super_pi, &1)})

    on_exit(fn ->
      Enum.each(saved, fn
        {k, {:ok, v}} -> Application.put_env(:super_pi, k, v)
        {k, :error} -> Application.delete_env(:super_pi, k)
      end)
    end)

    Application.put_env(:super_pi, :mock_llm, false)
    :ok
  end

  defp run_turn(model, tools) do
    conv =
      Storage.create_conversation!(
        agent: %{"model" => model, "tools" => tools, "executionMode" => "auto"}
      )

    {:ok, pid} = Machine.start_link(conversation_id: conv.id, extensions: [])
    {pid, conv}
  end

  defp anthropic_events(blocks) do
    start = [
      {"message_start",
       %{
         "type" => "message_start",
         "message" => %{
           "role" => "assistant",
           "content" => [],
           "usage" => %{"input_tokens" => 10, "output_tokens" => 1}
         }
       }}
    ]

    stop = [
      {"message_delta",
       %{
         "type" => "message_delta",
         "delta" => %{"stop_reason" => "end_turn"},
         "usage" => %{"output_tokens" => 5}
       }},
      {"message_stop", %{"type" => "message_stop"}}
    ]

    start ++ blocks ++ stop
  end

  test "Anthropic: tool use, tool execution, final answer" do
    tool_turn =
      anthropic_events([
        {"content_block_start",
         %{
           "type" => "content_block_start",
           "index" => 0,
           "content_block" => %{
             "type" => "tool_use",
             "id" => "toolu_1",
             "name" => "ls",
             "input" => %{}
           }
         }},
        {"content_block_delta",
         %{
           "type" => "content_block_delta",
           "index" => 0,
           "delta" => %{"type" => "input_json_delta", "partial_json" => ~s({"path": "lib"})}
         }},
        {"content_block_stop", %{"type" => "content_block_stop", "index" => 0}}
      ])

    final =
      anthropic_events([
        {"content_block_start",
         %{
           "type" => "content_block_start",
           "index" => 0,
           "content_block" => %{"type" => "text", "text" => ""}
         }},
        {"content_block_delta",
         %{
           "type" => "content_block_delta",
           "index" => 0,
           "delta" => %{"type" => "text_delta", "text" => "There is a lib directory."}
         }},
        {"content_block_stop", %{"type" => "content_block_stop", "index" => 0}}
      ])

    {url, _} = MockLLM.start([{200, MockLLM.sse(tool_turn)}, {200, MockLLM.sse(final)}])
    Application.put_env(:super_pi, :anthropic_api_key, "k")
    Application.put_env(:super_pi, :anthropic_base_url, url)

    {pid, _conv} =
      run_turn("claude-sonnet-5-5", [%{"name" => "ls", "description" => "List a directory"}])

    assert {:ok, msg} = Machine.submit(pid, "what is in lib?", timeout: 30_000)
    assert [%{"type" => "text", "text" => "There is a lib directory."}] = msg["content"]

    assert_receive {:llm_request, %{body: first}}
    assert_receive {:llm_request, %{body: second}}
    assert first["tools"] |> Enum.map(& &1["name"]) == ["ls"]

    # The second request has the assistant's tool_use and the tool_result for the same id.
    assert [
             _user,
             %{
               "role" => "assistant",
               "content" => [%{"type" => "tool_use", "id" => "toolu_1", "name" => "ls"}]
             },
             %{
               "role" => "user",
               "content" => [
                 %{"type" => "tool_result", "tool_use_id" => "toolu_1", "content" => result}
               ]
             }
           ] =
             second["messages"]

    assert result =~ "super_pi"
  end

  test "OpenAI: tool call, tool execution, final answer" do
    call = [
      %{
        "id" => "c",
        "object" => "chat.completion.chunk",
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{
              "role" => "assistant",
              "tool_calls" => [
                %{
                  "index" => 0,
                  "id" => "call_7",
                  "type" => "function",
                  "function" => %{"name" => "ls", "arguments" => ~s({"path": "lib"})}
                }
              ]
            }
          }
        ]
      },
      %{
        "id" => "c",
        "object" => "chat.completion.chunk",
        "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "tool_calls"}]
      },
      %{
        "id" => "c",
        "object" => "chat.completion.chunk",
        "choices" => [],
        "usage" => %{"prompt_tokens" => 9, "completion_tokens" => 4}
      },
      :done
    ]

    final = [
      %{
        "id" => "c",
        "object" => "chat.completion.chunk",
        "choices" => [
          %{"index" => 0, "delta" => %{"role" => "assistant", "content" => "Found lib."}}
        ]
      },
      %{
        "id" => "c",
        "object" => "chat.completion.chunk",
        "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}]
      },
      %{
        "id" => "c",
        "object" => "chat.completion.chunk",
        "choices" => [],
        "usage" => %{"prompt_tokens" => 30, "completion_tokens" => 3}
      },
      :done
    ]

    {url, _} = MockLLM.start([{200, MockLLM.sse(call)}, {200, MockLLM.sse(final)}])
    Application.put_env(:super_pi, :openai_api_key, "k")
    Application.put_env(:super_pi, :openai_base_url, url <> "/v1")

    {pid, conv} = run_turn("gpt-5", [%{"name" => "ls", "description" => "List a directory"}])
    assert {:ok, msg} = Machine.submit(pid, "what is in lib?", timeout: 30_000)
    assert [%{"type" => "text", "text" => "Found lib."}] = msg["content"]

    assert_receive {:llm_request, _}
    assert_receive {:llm_request, %{body: %{"messages" => messages}}}

    assert %{"role" => "tool", "tool_call_id" => "call_7"} =
             Enum.find(messages, &(&1["role"] == "tool"))

    assert %{"role" => "assistant", "tool_calls" => [%{"id" => "call_7"}]} =
             Enum.find(messages, &(&1["role"] == "assistant"))

    # Token usage reached the durable usage document.
    usage = SuperPi.Durable.Doc.snapshot("conversation", conv.id, "pi.usage")
    assert usage["inputTokens"] == 39
    assert usage["outputTokens"] == 7
  end

  test "a rejected key ends the turn with the provider's message" do
    {url, _} =
      MockLLM.start([{401, Jason.encode!(%{"error" => %{"message" => "invalid x-api-key"}})}])

    Application.put_env(:super_pi, :anthropic_api_key, "bad")
    Application.put_env(:super_pi, :anthropic_base_url, url)

    {pid, _} = run_turn("claude-sonnet-5-5", [])
    assert {:error, message} = Machine.submit(pid, "hi", timeout: 30_000)
    assert inspect(message) =~ "invalid x-api-key"
  end

  test "a rate limit becomes a backoff, and the turn finishes on the retry" do
    ok =
      anthropic_events([
        {"content_block_start",
         %{
           "type" => "content_block_start",
           "index" => 0,
           "content_block" => %{"type" => "text", "text" => ""}
         }},
        {"content_block_delta",
         %{
           "type" => "content_block_delta",
           "index" => 0,
           "delta" => %{"type" => "text_delta", "text" => "after the wait"}
         }},
        {"content_block_stop", %{"type" => "content_block_stop", "index" => 0}}
      ])

    {url, _} = MockLLM.start([{429, [{"retry-after", "0"}], "{}"}, {200, MockLLM.sse(ok)}])
    Application.put_env(:super_pi, :anthropic_api_key, "k")
    Application.put_env(:super_pi, :anthropic_base_url, url)

    {pid, _} = run_turn("claude-sonnet-5-5", [])

    assert {:ok, %{"content" => [%{"text" => "after the wait"}]}} =
             Machine.submit(pid, "hi", timeout: 30_000)
  end
end
