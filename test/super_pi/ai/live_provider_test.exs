defmodule SuperPi.AI.LiveProviderTest do
  @moduledoc """
  Opt-in smoke tests against real provider APIs. They cost money and need the network,
  so they are excluded by default and each one skips without its API key:

      GEMINI_API_KEY=... mix test --include live test/super_pi/ai/live_provider_test.exs

  Add one `describe` block per provider as it passes (Task 44).
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
      payload = %{model: model, messages: [user("Reply with the single word: pong")], system_sections: [], tools: []}

      assert {:ok, msg} = provider.generate(payload, on_delta: fn event -> send(me, {:delta, event}) end)
      assert msg["role"] == "assistant"

      text = msg["content"] |> Enum.filter(&(&1["type"] == "text")) |> Enum.map_join(& &1["text"])
      assert String.downcase(text) =~ "pong"
      assert_received {:delta, _}
    end
  end
end
