defmodule SuperPi.CompactionTest do
  use SuperPi.DataCase, async: false
  use ExUnitProperties

  alias SuperPi.Compaction
  alias SuperPi.Durable.{Context, Storage}

  describe "Property-Based Tests: 4-Mode Compaction & Cut-Point Tool-Pair Invariants (REQ-PBT-06)" do
    property "find_safe_cut_point never splits an assistant tool_call from its following tool result entries" do
      check all(
              turns <-
                list_of(
                  tuple({
                    member_of([:plain_turn, :tool_turn]),
                    string(:alphanumeric, min_length: 10, max_length: 80),
                    integer(1..3)
                  }),
                  min_length: 3,
                  max_length: 10
                ),
              keep_recent_tokens <- integer(10..500),
              max_runs: 40
            ) do
        conv = Storage.create_conversation!()

        Enum.with_index(turns, fn {kind, text, tool_count}, turn_idx ->
          Storage.append_entry!(conv.id, "pi.message", %{
            "role" => "user",
            "content" => [%{"type" => "text", "text" => "user_#{turn_idx}_#{text}"}]
          })

          case kind do
            :plain_turn ->
              Storage.append_entry!(conv.id, "pi.message", %{
                "role" => "assistant",
                "content" => [%{"type" => "text", "text" => "asst_#{turn_idx}_#{text}"}]
              })

            :tool_turn ->
              tool_calls =
                for i <- 1..tool_count do
                  %{
                    "type" => "tool_call",
                    "id" => "call_#{turn_idx}_#{i}",
                    "name" => "read",
                    "arguments" => %{"path" => "/tmp/f_#{i}"}
                  }
                end

              Storage.append_entry!(conv.id, "pi.message", %{
                "role" => "assistant",
                "content" => tool_calls
              })

              for i <- 1..tool_count do
                Storage.append_entry!(conv.id, "pi.message", %{
                  "role" => "tool",
                  "tool_call_id" => "call_#{turn_idx}_#{i}",
                  "name" => "read",
                  "content" => "result_#{turn_idx}_#{i}_#{text}"
                })
              end
          end
        end)

        {visible, _} = Context.visible_entries_with_graph(conv.id)

        {_prefix, tail, head_entry_id} =
          Compaction.find_safe_cut_point(visible, keep_recent_tokens)

        assert is_integer(head_entry_id)
        assert hd(tail).id == head_entry_id

        # INVARIANT 1: The kept tail MUST NEVER start with an orphaned `role == "tool"` message
        refute match?(%{kind: "pi.message", data: %{"role" => "tool"}}, hd(tail))

        # INVARIANT 2: Every `role == "tool"` entry in `tail` must have its matching `tool_call` assistant message in `tail`
        kept_tool_call_ids =
          tail
          |> Enum.filter(&(&1.kind == "pi.message" and &1.data["role"] == "assistant"))
          |> Enum.flat_map(fn e ->
            (e.data["content"] || [])
            |> Enum.filter(&(&1["type"] == "tool_call"))
            |> Enum.map(& &1["id"])
          end)
          |> MapSet.new()

        tail
        |> Enum.filter(&(&1.kind == "pi.message" and &1.data["role"] == "tool"))
        |> Enum.each(fn tool_entry ->
          assert MapSet.member?(kept_tool_call_ids, tool_entry.data["tool_call_id"])
        end)
      end
    end

    test "supports manual, threshold, background (Oban), and overflow compaction modes and updates Context.derive" do
      conv = Storage.create_conversation!()

      for i <- 1..6 do
        Storage.append_entry!(conv.id, "pi.message", %{
          "role" => "user",
          "content" => [
            %{"type" => "text", "text" => "Question #{i} " <> String.duplicate("x", 100)}
          ]
        })

        Storage.append_entry!(conv.id, "pi.message", %{
          "role" => "assistant",
          "content" => [
            %{"type" => "text", "text" => "Answer #{i} " <> String.duplicate("y", 100)}
          ]
        })
      end

      # Check threshold policy with a low window
      assert {:threshold, _} =
               Compaction.check_policy(conv.id, context_window: 100, reserve_tokens: 50)

      assert {:background, _} =
               Compaction.check_policy(conv.id, context_window: 50_000, background_tokens: 50)

      # Execute threshold compaction keeping only ~100 tokens
      {:ok, res} = Compaction.compact!(conv.id, :threshold, keep_recent_tokens: 100)
      assert res.mode == :threshold
      assert res.compacted_count > 0
      assert res.kept_count > 0

      derived = Context.derive(conv.id)
      # First derived message after compaction is the synthetic compaction summary message
      first_msg = hd(derived.messages)
      assert String.contains?(Jason.encode!(first_msg), "threshold compaction summary")
      assert length(derived.messages) == res.kept_count + 1

      # Enqueue background compaction job via Oban
      assert {:enqueued, job} =
               Compaction.compact!(conv.id, :background, enqueue: true, keep_recent_tokens: 80)

      assert job.queue == "compaction"
    end
  end
end
