defmodule SuperPi.AI.LiveProviderTest do
  @moduledoc """
  Opt-in smoke tests against real provider APIs. They cost money and need the network,
  so they are excluded by default and each one skips without its API key:

      GEMINI_API_KEY=... mix test --include live test/super_pi/ai/live_provider_test.exs

      ANTHROPIC_API_KEY=... mix test --include live test/super_pi/ai/live_provider_test.exs
      OPENAI_API_KEY=...    mix test --include live test/super_pi/ai/live_provider_test.exs

  Each block skips without its key. The Anthropic and OpenAI blocks have never run with a real key.
  Set `ANTHROPIC_LIVE_MODEL` or `OPENAI_LIVE_MODEL` to test another model.
  """
  use ExUnit.Case, async: false

  alias SuperPi.AI.Providers

  @moduletag :live
  @moduletag timeout: 120_000

  defp user(text), do: %{"role" => "user", "content" => text}

  describe "gemini" do
    if System.get_env("GEMINI_API_KEY") in [nil, ""] do
      @describetag skip: "GEMINI_API_KEY is not set"
    end

    test "resolves, generates text and streams deltas" do
      Application.put_env(:super_pi, :mock_llm, false)
      assert {:ok, provider, model} = Providers.resolve("gemini-3-flash-preview")
      assert provider == SuperPi.AI.Providers.Gemini

      me = self()

      payload = %{
        model: model,
        messages: [user("Reply with the single word: pong")],
        system_sections: [],
        tools: []
      }

      assert {:ok, msg} =
               provider.generate(payload, on_delta: fn event -> send(me, {:delta, event}) end)

      assert msg["role"] == "assistant"

      text = msg["content"] |> Enum.filter(&(&1["type"] == "text")) |> Enum.map_join(& &1["text"])
      assert String.downcase(text) =~ "pong"
      assert_received {:delta, _}
    end
  end

  defp ask_tool_then_answer(provider, model) do
    me = self()

    tool = %{
      "name" => "read",
      "description" => "Read a file",
      "parameters" => SuperPi.AI.ToolSchemas.for_tool("read")
    }

    first = %{
      model: model,
      system_sections: [],
      tools: [tool],
      messages: [user("Use the read tool to read mix.exs. Do not answer before you call it.")]
    }

    assert {:ok, msg} = provider.generate(first, on_delta: fn ev -> send(me, {:delta, ev}) end)

    assert %{"id" => id, "name" => "read", "arguments" => %{"path" => _}} =
             Enum.find(msg["content"], &(&1["type"] == "tool_call"))

    assert msg["usage"]["input_tokens"] > 0
    assert_received {:delta, _}

    # Send the result back: the provider must accept its own tool-call format.
    second = %{
      first
      | messages:
          first.messages ++
            [
              Map.take(msg, ["role", "content"]),
              %{"role" => "tool", "tool_call_id" => id, "content" => "defmodule Demo do\nend"}
            ]
    }

    assert {:ok, final} = provider.generate(second, [])
    text = final["content"] |> Enum.filter(&(&1["type"] == "text")) |> Enum.map_join(& &1["text"])
    assert text != ""
  end

  describe "anthropic" do
    if System.get_env("ANTHROPIC_API_KEY") in [nil, ""] do
      @describetag skip: "ANTHROPIC_API_KEY is not set"
    end

    test "text, a tool call and the tool result" do
      model = System.get_env("ANTHROPIC_LIVE_MODEL") || "claude-haiku-5-5"
      assert {:ok, provider, normalized} = Providers.resolve(model)
      assert provider == SuperPi.AI.Providers.Anthropic

      assert {:ok, msg} =
               provider.generate(
                 %{
                   model: normalized,
                   system_sections: [],
                   tools: [],
                   messages: [user("Reply with the single word: pong")]
                 },
                 []
               )

      assert msg["content"] |> Enum.map_join(&(&1["text"] || "")) |> String.downcase() =~ "pong"

      ask_tool_then_answer(provider, normalized)
    end
  end

  describe "openai" do
    if System.get_env("OPENAI_API_KEY") in [nil, ""] do
      @describetag skip: "OPENAI_API_KEY is not set"
    end

    test "text, a tool call and the tool result" do
      model = System.get_env("OPENAI_LIVE_MODEL") || "gpt-5-mini"
      assert {:ok, provider, normalized} = Providers.resolve(model)
      assert provider == SuperPi.AI.Providers.OpenAI

      assert {:ok, msg} =
               provider.generate(
                 %{
                   model: normalized,
                   system_sections: [],
                   tools: [],
                   messages: [user("Reply with the single word: pong")]
                 },
                 []
               )

      assert msg["content"] |> Enum.map_join(&(&1["text"] || "")) |> String.downcase() =~ "pong"

      ask_tool_then_answer(provider, normalized)
    end
  end
end
