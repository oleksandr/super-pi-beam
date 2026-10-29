defmodule SuperPi.AI.VirtualModelDefectsTest do
  @moduledoc """
  Regression tests that reproduce `SuperPi.AI.VirtualModel` defects found in the
  code review. Every test is expected to FAIL on the current code and pass once the
  matching finding is fixed.

  Run only these:  mix test --only known_bug
  Skip these:      mix test --exclude known_bug
  """
  use SuperPi.DataCase, async: false

  alias SuperPi.AI.VirtualModel
  alias SuperPi.Durable.Doc
  alias SuperPi.Durable.Storage


  defp attempt(fun) do
    {:ok, fun.()}
  rescue
    e -> {:raised, e}
  end

  describe "ensure_provider_session!/3 (virtual_model.ex:83-106)" do
    test "an unchanged provider does not rewrite the pi.provider doc on every call" do
      conv = Storage.create_conversation!()
      VirtualModel.ensure_provider_session!(conv.id, :anthropic, "claude-sonnet-4-5")
      first = Doc.snapshot("conversation", conv.id, "pi.provider")

      Process.sleep(5)
      VirtualModel.ensure_provider_session!(conv.id, :anthropic, "claude-sonnet-4-5")
      second = Doc.snapshot("conversation", conv.id, "pi.provider")

      assert second == first, "lastWarmedAt changed, forcing a DB commit on every call"
    end

    test "concurrent first calls agree on one session id" do
      conv = Storage.create_conversation!()
      Storage.commit(fn seq -> Doc.put_doc("conversation", conv.id, "pi.provider", %{}, seq) end)

      ids =
        1..12
        |> Enum.map(fn _ -> Task.async(fn -> VirtualModel.ensure_provider_session!(conv.id, :anthropic, "m") end) end)
        |> Enum.map(&Task.await(&1, 10_000))
        |> Enum.map(& &1["sessionId"])
        |> Enum.uniq()

      assert length(ids) == 1, "#{length(ids)} different session ids minted"
      assert Doc.snapshot("conversation", conv.id, "pi.provider")["sessionId"] in ids
    end

    test "a conversation without a pi.provider doc does not raise" do
      # no conversation (and so no seeded doc) exists under this id
      conv_id = 424_242
      assert Doc.snapshot("conversation", conv_id, "pi.provider") == nil

      result = attempt(fn -> VirtualModel.ensure_provider_session!(conv_id, :anthropic, "m") end)
      assert {:ok, %{"sessionId" => id}} = result, "got #{inspect(result)}"
      assert is_binary(id)
    end
  end

  describe "resolve/2 (virtual_model.ex:58-75,108-111)" do
    test "an unknown provider prefix is not silently mapped to anthropic" do
      result = attempt(fn -> VirtualModel.resolve("mistral/large") end)
      refute match?({:ok, %{provider: :anthropic}}, result), "unknown provider fell back to :anthropic"
    end

    test "a bare non-Claude model name is not silently routed to anthropic" do
      result = attempt(fn -> VirtualModel.resolve("gpt-5") end)
      refute match?({:ok, %{provider: :anthropic}}, result), "gpt-5 resolved to the anthropic provider"
    end

    test "an empty model spec is rejected instead of producing model \"\"" do
      result = attempt(fn -> VirtualModel.resolve("") end)
      refute match?({:ok, %{model: ""}}, result), "resolved to an empty model id"
    end

    test "a provider prefix with an empty model id is rejected" do
      result = attempt(fn -> VirtualModel.resolve("openai/") end)
      refute match?({:ok, %{model: ""}}, result), "resolved to an empty model id"
    end
  end
end
