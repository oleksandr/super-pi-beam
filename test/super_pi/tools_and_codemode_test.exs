defmodule SuperPi.ToolsAndCodeModeTest do
  use SuperPi.DataCase, async: false
  use ExUnitProperties

  alias SuperPi.CodeMode.Journal
  alias SuperPi.Durable.{Storage, TaskEngine}
  alias SuperPi.Tools

  describe "Property-Based Tests: Codemode Deterministic Replay & 3-Channel Tools (Decision 06 & 07)" do
    property "Codemode script crash at any step replays completed tool calls with zero duplicate side effects on restart" do
      check all(
              step_names <- list_of(member_of(["read", "write", "edit", "bash", "grep"]), min_length: 3, max_length: 10),
              crash_idx <- integer(0..8),
              max_runs: 30
            ) do
        total_steps = length(step_names)
        actual_crash_idx = rem(crash_idx, total_steps)

        conv = Storage.create_conversation!()
        {:ok, task} = TaskEngine.create_task(conv.id, "pi.codemode", %{"steps" => total_steps})
        {:ok, _} = TaskEngine.start_task(task.id)

        steps_spec =
          Enum.with_index(step_names, fn name, idx ->
            {name, %{"step" => idx, "arg" => "val_#{idx}"}}
          end)

        # Track side-effect counter per step index
        counter_ref = :counters.new(total_steps, [:atomics])

        executor_fun = fn tool_name, %{"step" => idx} = args ->
          :counters.add(counter_ref, idx + 1, 1)

          %{
            "output" => "ran:#{tool_name}:#{idx}",
            "structured_output" => args,
            "details" => %{"step" => idx}
          }
        end

        # First run crashes right after `actual_crash_idx` has been persisted to the journal
        assert_raise RuntimeError, fn ->
          Journal.run_script(task.id, steps_spec, executor_fun, simulate_crash_at_index: actual_crash_idx)
        end

        # Reconcile task on open (simulating node/worker restart)
        [_reconciled] = TaskEngine.reconcile_on_open!(conv.id)
        {:ok, _} = TaskEngine.start_task(task.id)

        # Second run completes all steps without crashing
        outcomes = Journal.run_script(task.id, steps_spec, executor_fun)
        assert length(outcomes) == total_steps

        # Steps 0..actual_crash_idx MUST be :replayed; steps (actual_crash_idx + 1)..(total_steps - 1) MUST be :executed
        Enum.each(outcomes, fn %{index: idx, mode: mode} ->
          if idx <= actual_crash_idx do
            assert mode == :replayed
          else
            assert mode == :executed
          end

          # Every single step's side effect ran AT MOST AND AT LEAST ONCE (exactly 1 time total!)
          assert :counters.get(counter_ref, idx + 1) == 1
        end)
      end
    end

    test "5 ToolExposure modes and deferred tool_search dynamically discover and activate deferred tools" do
      Tools.register_tool!(
        %{"name" => "kubernetes_deploy", "description" => "Deploy helm chart to k8s cluster"},
        :deferred
      )

      Tools.register_tool!(
        %{"name" => "internal_secret_audit", "description" => "Hidden internal tool"},
        :hidden
      )

      active = Tools.active_llm_tools()
      active_names = Enum.map(active, & &1["name"])

      assert "read" in active_names
      assert "tool_search" in active_names
      refute "kubernetes_deploy" in active_names
      refute "internal_secret_audit" in active_names

      # Model invokes `tool_search` for "k8s"
      search_res = Tools.execute("tool_search", %{"query" => "k8s"})
      assert [%{"name" => "kubernetes_deploy"}] = search_res["control"]["add_tools"]
      assert search_res["structured_output"]["count"] == 1
    end

    test "built-in read, write, edit, grep, find, and ls return 3-channel outputs" do
      tmp_dir = Path.join(System.tmp_dir!(), "super_pi_tools_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)
      file_path = Path.join(tmp_dir, "hello.txt")

      w_res = Tools.execute("write", %{"path" => file_path, "content" => "line1\nline2\n"})
      assert w_res["structured_output"]["bytes"] == 12

      e_res = Tools.execute("edit", %{"path" => file_path, "old_text" => "line2", "new_text" => "line2_edited"})
      assert e_res["structured_output"]["replacements"] == 1

      r_res = Tools.execute("read", %{"path" => file_path})
      assert String.contains?(r_res["output"], "line2_edited")

      g_res = Tools.execute("grep", %{"path" => tmp_dir, "pattern" => "line2_edited"})
      assert g_res["structured_output"]["count"] == 1

      f_res = Tools.execute("find", %{"path" => tmp_dir})
      assert "hello.txt" in f_res["structured_output"]["files"]

      File.rm_rf!(tmp_dir)
    end
  end
end
