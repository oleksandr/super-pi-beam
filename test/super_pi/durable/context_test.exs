defmodule SuperPi.Durable.ContextTest do
  use SuperPi.DataCase, async: false
  use ExUnitProperties

  alias SuperPi.Durable.{Context, Storage}

  describe "Property-Based Tests: 10-Rule Context Derivation (REQ-PBT-02)" do
    property "positional pi.system deltas reconstruct exact prompt sections and tools while avoiding redundant entries" do
      check all(
              section_updates <-
                list_of(
                  fixed_map(%{
                    base: member_of(["You are a coding agent.", "You are a reviewer."]),
                    git: member_of(["branch: main", "branch: feat/beam", "branch: fix/cache"]),
                    tools:
                      map(
                        list_of(member_of(["read", "write", "edit", "bash", "grep", "tool_search"]),
                          min_length: 1,
                          max_length: 5
                        ),
                        &Enum.uniq/1
                      )
                  }),
                  min_length: 2,
                  max_length: 10
                ),
              max_runs: 25
            ) do
        conv = Storage.create_conversation!()

        Enum.reduce(section_updates, nil, fn step, prev_step ->
          sections = [
            %{"id" => "base", "content" => step.base},
            %{"id" => "git", "content" => step.git}
          ]

          # Each tool keeps its parameter schema; a built-in without one gets the built-in schema.
          tools =
            Enum.map(step.tools, &%{"name" => &1, "description" => "Tool #{&1}", "parameters" => SuperPi.AI.ToolSchemas.for_tool(&1)})

          {mode, _entry} = Context.ensure_system_state!(conv.id, sections, tools)

          same_sections = prev_step != nil and prev_step.base == step.base and prev_step.git == step.git
          same_tools = prev_step != nil and MapSet.new(prev_step.tools) == MapSet.new(step.tools)

          cond do
            prev_step == nil ->
              assert mode == :full

            same_sections and same_tools ->
              assert mode == :unchanged

            true ->
              assert mode == :delta
          end

          derived = Context.derive(conv.id)
          assert derived.system_sections == sections
          assert MapSet.new(derived.tools) == MapSet.new(tools)
          assert derived.system_prompt == "#{step.base}\n\n#{step.git}"
          step
        end)
      end
    end

    property "head markers (pi.compaction and pi.reset) exclude all preceding messages while preserving system state" do
      check all(
              pre_msgs <- list_of(string(:alphanumeric, min_length: 1, max_length: 20), min_length: 2, max_length: 6),
              kept_msgs <- list_of(string(:alphanumeric, min_length: 1, max_length: 20), min_length: 1, max_length: 5),
              post_msgs <- list_of(string(:alphanumeric, min_length: 1, max_length: 20), min_length: 1, max_length: 5),
              max_runs: 25
            ) do
        conv = Storage.create_conversation!()

        Context.ensure_system_state!(
          conv.id,
          [%{"id" => "core", "content" => "System instructions"}],
          [%{"name" => "read", "description" => "Read file"}]
        )

        _pre_entries =
          Enum.map(pre_msgs, fn text ->
            Storage.append_entry!(conv.id, "pi.message", %{"role" => "user", "content" => text})
          end)

        kept_entries =
          Enum.map(kept_msgs, fn text ->
            Storage.append_entry!(conv.id, "pi.message", %{"role" => "assistant", "content" => text})
          end)

        first_kept_id = hd(kept_entries).id

        _compaction =
          Storage.append_entry!(
            conv.id,
            "pi.compaction",
            %{"summary" => "Summarized pre_msgs"},
            head_entry_id: first_kept_id
          )

        _post_entries =
          Enum.map(post_msgs, fn text ->
            Storage.append_entry!(conv.id, "pi.message", %{"role" => "user", "content" => text})
          end)

        derived = Context.derive(conv.id)
        contents = Enum.map(derived.messages, & &1["content"])

        assert contents == ["Summarized pre_msgs"] ++ kept_msgs ++ post_msgs
        assert derived.system_prompt == "System instructions"
      end
    end

    property "non-destructive ContextEdits (omit and replace) transform derived messages without mutating stored Ecto rows" do
      check all(
              texts <- uniq_list_of(string(:alphanumeric, min_length: 3, max_length: 20), min_length: 3, max_length: 8),
              max_runs: 25
            ) do
        conv = Storage.create_conversation!()

        entries =
          Enum.map(texts, fn t ->
            Storage.append_entry!(conv.id, "pi.message", %{"role" => "user", "content" => t})
          end)

        [first_entry, second_entry | rest_entries] = entries

        _edit_entry =
          Storage.append_entry!(
            conv.id,
            "pi.message",
            %{"role" => "assistant", "content" => "Applied edits"},
            edits: [
              %{"op" => "omit", "target_id" => first_entry.id},
              %{
                "op" => "replace",
                "target_id" => second_entry.id,
                "replacement" => %{"role" => "user", "content" => "[REDACTED]"}
              }
            ]
          )

        derived = Context.derive(conv.id)
        contents = Enum.map(derived.messages, & &1["content"])

        expected =
          ["[REDACTED]"] ++
            Enum.map(rest_entries, & &1.data["content"]) ++
            ["Applied edits"]

        assert contents == expected

        # Verify original database rows remain untouched in Ecto
        assert Repo.get!(SuperPi.Durable.Schemas.Entry, first_entry.id).data["content"] == hd(texts)
        assert Repo.get!(SuperPi.Durable.Schemas.Entry, second_entry.id).data["content"] == Enum.at(texts, 1)
      end
    end

    property "multi-level fork DAG ancestry includes parent entries only up to parent_entry_id" do
      check all(
              root_count <- integer(2..6),
              fork_idx <- integer(0..(root_count - 1)),
              child_count <- integer(1..5),
              max_runs: 20
            ) do
        root = Storage.create_conversation!()

        root_entries =
          for i <- 1..root_count do
            Storage.append_entry!(root.id, "pi.message", %{"role" => "user", "content" => "root_#{i}"})
          end

        fork_target = Enum.at(root_entries, fork_idx)
        child = Storage.fork_conversation!(root.id, fork_target.id)

        # Append extra entries to root AFTER the fork; child must never see them
        _late_root =
          Storage.append_entry!(root.id, "pi.message", %{"role" => "user", "content" => "root_after_fork"})

        for j <- 1..child_count do
          Storage.append_entry!(child.id, "pi.message", %{"role" => "assistant", "content" => "child_#{j}"})
        end

        derived = Context.derive(child.id)
        contents = Enum.map(derived.messages, & &1["content"])

        expected_root_prefix = for i <- 1..(fork_idx + 1), do: "root_#{i}"
        expected_child_suffix = for j <- 1..child_count, do: "child_#{j}"

        assert contents == expected_root_prefix ++ expected_child_suffix
        assert Graph.vertices(derived.ancestry_graph) |> Enum.sort() == Enum.sort([root.id, child.id])
      end
    end
  end
end
