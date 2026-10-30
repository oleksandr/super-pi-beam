defmodule SuperPi.Durable.StorageTest do
  use SuperPi.DataCase, async: false
  use ExUnitProperties

  alias SuperPi.Durable.{DeferredFlusher, Doc, Storage}

  describe "root conversation and 5 built-in documents" do
    test "lazily creates root conversation (id=1) with built-in documents" do
      root =
        Storage.ensure_root_conversation!(%{
          "model" => "claude-sonnet-4",
          "thinkingLevel" => "medium"
        })

      assert root.id == 1
      assert root.owner_kind == "ownerless"

      agent_doc = Doc.snapshot("conversation", root.id, "pi.agent")
      assert agent_doc == %{"model" => "claude-sonnet-4", "thinkingLevel" => "medium"}

      provider_doc = Doc.snapshot("conversation", root.id, "pi.provider")
      assert is_binary(provider_doc["sessionId"])
      assert String.length(provider_doc["sessionId"]) == 36

      assert Doc.snapshot("conversation", root.id, "pi.live") == %{"status" => "idle"}
      assert Doc.snapshot("conversation", root.id, "pi.inbox") == %{"queued" => []}

      assert Doc.snapshot("conversation", root.id, "pi.usage") == %{
               "inputTokens" => 0,
               "outputTokens" => 0,
               "costUsd" => 0.0
             }

      root2 = Storage.ensure_root_conversation!(%{"model" => "ignored"})
      assert root2.id == 1
      assert Doc.snapshot("conversation", root2.id, "pi.agent") == agent_doc
      assert Doc.snapshot("conversation", root2.id, "pi.provider") == provider_doc
    end
  end

  describe "Property-Based Tests: Storage, Rewindable Documents, Forks, and DeferredFlusher" do
    property "monotonic Seq strictly increases across arbitrary interleaved operations" do
      check all(
              ops <-
                list_of(
                  member_of([:append_entry, :configure_agent, :stage_deferred]),
                  min_length: 3,
                  max_length: 12
                ),
              max_runs: 20
            ) do
        conv = Storage.create_conversation!(agent: %{"model" => "sonnet"})

        seqs =
          Enum.reduce(ops, [conv.created_seq], fn
            :append_entry, acc ->
              e = Storage.append_entry!(conv.id, "pi.message", %{"text" => "msg"})
              [e.seq | acc]

            :configure_agent, acc ->
              Storage.configure_agent!(conv.id, %{"step" => length(acc)})
              [Storage.current_seq() | acc]

            :stage_deferred, acc ->
              DeferredFlusher.stage_deferred("conversation", conv.id, "pi.live", %{
                "tokens" => length(acc)
              })

              acc
          end)
          |> Enum.reverse()

        assert seqs == Enum.sort(seqs)
        assert seqs == Enum.uniq(seqs)
      end
    end

    property "snapshot_as_of reconstructs exact historical document state across Jsonpatch deltas and checkpoints" do
      check all(
              steps <-
                list_of(
                  fixed_map(%{
                    model: member_of(["sonnet", "opus", "haiku", "gemini-pro"]),
                    thinking: member_of(["low", "medium", "high"]),
                    tools:
                      list_of(member_of(["read", "write", "edit", "bash", "grep"]), max_length: 4)
                  }),
                  min_length: 2,
                  max_length: 10
                ),
              max_runs: 25
            ) do
        conv = Storage.create_conversation!(agent: %{})

        history =
          steps
          |> Enum.with_index(1)
          |> Enum.map(fn {cfg, idx} ->
            expected = %{
              "model" => cfg.model,
              "thinking" => cfg.thinking,
              "tools" => Enum.uniq(cfg.tools),
              "turn" => idx
            }

            Storage.configure_agent!(conv.id, expected)
            entry = Storage.append_entry!(conv.id, "pi.message", %{"idx" => idx})
            {entry.seq, entry.id, expected}
          end)

        # Wipe ETS cache to force Ecto base + Jsonpatch delta replay
        :ets.delete_all_objects(:super_pi_doc_cache)

        for {seq, _entry_id, expected} <- history do
          assert Doc.snapshot_as_of(conv.id, "pi.agent", seq) == expected
        end

        # Fork at the midpoint entry and verify asOf inheritance + ancestral lookup
        {mid_seq, mid_entry_id, mid_expected} = Enum.at(history, div(length(history), 2))
        fork = Storage.fork_conversation!(conv.id, mid_entry_id)

        assert Doc.snapshot("conversation", fork.id, "pi.agent") == mid_expected
        assert Doc.snapshot_as_of(fork.id, "pi.agent", mid_seq) == mid_expected

        parent_uuid = Doc.snapshot("conversation", conv.id, "pi.provider")["sessionId"]
        fork_uuid = Doc.snapshot("conversation", fork.id, "pi.provider")["sessionId"]
        assert parent_uuid != fork_uuid
      end
    end

    property "DeferredFlusher coalesces rapid 100ms ETS bursts and persists latest state on next durable commit" do
      check all(
              partials <-
                list_of(string(:alphanumeric, min_length: 1, max_length: 30),
                  min_length: 2,
                  max_length: 15
                ),
              max_runs: 25
            ) do
        conv = Storage.create_conversation!()

        Enum.each(partials, fn chunk ->
          DeferredFlusher.stage_deferred("conversation", conv.id, "pi.live", %{
            "status" => "streaming",
            "partialText" => chunk
          })
        end)

        expected_last = %{
          "status" => "streaming",
          "partialText" => List.last(partials)
        }

        assert Doc.snapshot("conversation", conv.id, "pi.live") == expected_last
        assert DeferredFlusher.pending_count() == 1

        # Next immediate commit flushes pending deferred state atomically
        _entry = Storage.append_entry!(conv.id, "pi.message", %{"done" => true})
        assert DeferredFlusher.pending_count() == 0

        :ets.delete_all_objects(:super_pi_doc_cache)
        assert Doc.snapshot("conversation", conv.id, "pi.live") == expected_last
      end
    end
  end
end
