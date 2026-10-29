defmodule SuperPi.CompactionDefectsTest do
  @moduledoc """
  Regression tests that reproduce compaction defects found in the code review
  (see vault note "20 - Codebase Review Findings"). Every test is expected to
  FAIL on the current code and pass once the matching finding is fixed.

  Run only these:  mix test --only known_bug
  Skip these:      mix test --exclude known_bug
  """
  use SuperPi.DataCase, async: false

  import Ecto.Query

  alias SuperPi.Compaction
  alias SuperPi.Conversation.Machine
  alias SuperPi.Durable.{Context, Storage}
  alias SuperPi.Durable.Schemas.Entry
  alias SuperPi.TestSupport.Faults
  alias SuperPi.Workers.CompactionWorker


  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  defp msg!(conv_id, role, text) do
    Storage.append_entry!(conv_id, "pi.message", %{
      "role" => role,
      "content" => [%{"type" => "text", "text" => text}]
    })
  end

  defp text_pairs!(conv_id, n) do
    for i <- 1..n do
      msg!(conv_id, "user", "user #{i} " <> String.duplicate("u", 400))
      msg!(conv_id, "assistant", "assistant #{i} " <> String.duplicate("a", 400))
    end
  end

  defp tool_turn!(conv_id) do
    msg!(conv_id, "user", "please read the file")

    Storage.append_entry!(conv_id, "pi.message", %{
      "role" => "assistant",
      "content" => [%{"type" => "tool_call", "id" => "c1", "name" => "read", "arguments" => %{"path" => "/x"}}]
    })

    Storage.append_entry!(conv_id, "pi.message", %{
      "role" => "tool",
      "tool_call_id" => "c1",
      "name" => "read",
      "content" => "file contents",
      "is_error" => false
    })
  end

  defp compaction_entries(conv_id) do
    Repo.all(from e in Entry, where: e.conversation_id == ^conv_id and e.kind == "pi.compaction")
  end

  defp orphan_tool_messages(messages) do
    {orphans, _seen} =
      Enum.reduce(messages, {[], MapSet.new()}, fn
        %{"role" => "assistant", "content" => c}, {orph, seen} when is_list(c) ->
          ids = for %{"type" => "tool_call", "id" => id} <- c, do: id
          {orph, Enum.reduce(ids, seen, &MapSet.put(&2, &1))}

        %{"role" => "tool", "tool_call_id" => id}, {orph, seen} ->
          if MapSet.member?(seen, id), do: {orph, seen}, else: {[id | orph], seen}

        _, acc ->
          acc
      end)

    orphans
  end

  describe "Machine :default compaction ignores SuperPi.Compaction (machine.ex:494-538,611-615)" do
    setup do
      conv = Storage.create_conversation!()
      tool_turn!(conv.id)
      {:ok, pid} = Machine.start_link(conversation_id: conv.id)
      %{conv: conv, pid: pid}
    end

    test "derived context after compaction has no orphan role=tool message", %{conv: conv, pid: pid} do
      assert {:ok, _} = Machine.compact(pid)

      messages = Context.derive(conv.id).messages

      assert orphan_tool_messages(messages) == [],
             "orphan tool results after compaction: #{inspect(messages)}"
    end

    test "summary is a real summary, not the 'Compacted N entries.' stub", %{conv: conv, pid: pid} do
      assert {:ok, %{summary: summary}} = Machine.compact(pid)

      refute summary =~ ~r/^Compacted \d+ entries\.$/, "stub summary: #{inspect(summary)}"
      assert [%Entry{data: %{"summary" => ^summary}}] = compaction_entries(conv.id)
    end
  end

  describe "CompactionWorker only broadcasts (workers/oban_workers.ex:29-38)" do
    test "perform_job creates a pi.compaction entry" do
      conv = Storage.create_conversation!()
      text_pairs!(conv.id, 6)

      assert :ok =
               Oban.Testing.perform_job(
                 CompactionWorker,
                 %{"conversation_id" => conv.id, "keep_recent_tokens" => 200},
                 []
               )

      assert [_ | _] = compaction_entries(conv.id), "worker did not compact the conversation"
    end
  end

  describe "check_policy has no production caller (compaction.ex:102)" do
    test "a run that pushes the conversation over the default threshold triggers compaction" do
      # NOTE: no configuration hook exists on the machine, so this uses the default
      # context window (200_000 tokens) with a ~225k-token history.
      conv = Storage.create_conversation!()
      msg!(conv.id, "user", String.duplicate("x", 900_000))
      msg!(conv.id, "assistant", "ack")

      {:ok, pid} =
        Machine.start_link(
          conversation_id: conv.id,
          llm_responder: fn _p, _c -> {:ok, Faults.text_msg("ok")} end
        )

      assert {:ok, _} = Machine.submit(pid, "next", timeout: 5_000)
      assert {:threshold, _} = Compaction.check_policy(conv.id), "precondition: history over threshold"
      assert [_ | _] = compaction_entries(conv.id), "no compaction after exceeding the threshold"
    end
  end

  describe "compaction ignores the head slice (compaction.ex:107-108,144-145)" do
    setup do
      conv = Storage.create_conversation!()
      text_pairs!(conv.id, 5)
      %{conv: conv}
    end

    test "check_policy stops counting hidden entries after a compaction", %{conv: conv} do
      opts = [context_window: 1_000, reserve_tokens: 0, background_tokens: 1_000_000_000]
      assert {:threshold, _} = Compaction.check_policy(conv.id, opts)

      assert {:ok, _} = Compaction.compact!(conv.id, :manual, keep_recent_tokens: 300)

      assert Compaction.check_policy(conv.id, opts) == :none,
             "hidden (compacted) entries are still counted"
    end

    test "second compact! does not re-scan the hidden prefix", %{conv: conv} do
      assert {:ok, _} = Compaction.compact!(conv.id, :manual, keep_recent_tokens: 300)
      active = length(Context.derive(conv.id).active_entries)

      assert {:ok, second} = Compaction.compact!(conv.id, :manual, keep_recent_tokens: 300)

      assert second.compacted_count <= active,
             "compactedCount #{second.compacted_count} exceeds the #{active} active entries"
    end

    test "a large keep_recent_tokens cannot move the head before an earlier compaction head", %{conv: conv} do
      assert {:ok, first} = Compaction.compact!(conv.id, :manual, keep_recent_tokens: 300)
      assert {:ok, second} = Compaction.compact!(conv.id, :manual, keep_recent_tokens: 100_000)

      assert second.head_entry_id >= first.head_entry_id,
             "earlier compacted history un-hidden: #{first.head_entry_id} -> #{second.head_entry_id}"
    end
  end

  describe "compacting a trivial conversation (compaction.ex:57-59,177-178)" do
    test "<= 1 message returns {:ok, :noop} and appends no entry" do
      conv = Storage.create_conversation!()
      msg!(conv.id, "user", "only message")

      assert Compaction.compact!(conv.id, :manual) == {:ok, :noop}
      assert compaction_entries(conv.id) == []
    end
  end
end
