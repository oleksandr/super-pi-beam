defmodule SuperPi.EnvTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias SuperPi.Env.{Local, SandboxRunner}

  describe "Property-Based Tests: 4-Layer Tool Safety, FileLock Serialization, & Crash Immunity (REQ-PBT-05)" do
    property "concurrent parallel edit_file mutations on the same file serialize cleanly with zero lost updates" do
      check all(
              worker_count <- integer(8..20),
              token_prefix <- string(:alphanumeric, min_length: 4, max_length: 10),
              max_runs: 25
            ) do
        tmp_file = Path.join(System.tmp_dir!(), "super_pi_lock_test_#{System.unique_integer([:positive])}.txt")

        initial_lines =
          for i <- 1..worker_count do
            "PLACEHOLDER_#{token_prefix}_#{i}=0"
          end

        :ok = Local.write_file(tmp_file, Enum.join(initial_lines, "\n"))

        # Spawn `worker_count` concurrent tasks mutating the exact same file simultaneously
        tasks =
          for i <- 1..worker_count do
            Task.async(fn ->
              old_str = "PLACEHOLDER_#{token_prefix}_#{i}=0"
              new_str = "UPDATED_#{token_prefix}_#{i}=1"
              Local.edit_file(tmp_file, old_str, new_str)
            end)
          end

        results = Task.await_many(tasks, 15_000)

        assert Enum.all?(results, fn res -> res == {:ok, %{replacements: 1}} end)

        {:ok, final_content} = Local.read_file(tmp_file)

        for i <- 1..worker_count do
          assert String.contains?(final_content, "UPDATED_#{token_prefix}_#{i}=1")
          refute String.contains?(final_content, "PLACEHOLDER_#{token_prefix}_#{i}=0")
        end

        File.rm(tmp_file)
      end
    end

    property "SandboxRunner isolates exceptions, exits, timeouts, and heap OOM kills without ever crashing the caller" do
      check all(
              fault_kind <- member_of([:raise_exception, :throw_exit, :killed, :heap_oom, :timeout, :ok_value]),
              payload <- string(:alphanumeric, min_length: 3, max_length: 20),
              max_runs: 40
            ) do
        caller_pid = self()

        result =
          case fault_kind do
            :raise_exception ->
              SandboxRunner.run_isolated(fn ->
                raise RuntimeError, "simulated tool failure: #{payload}"
              end)

            :throw_exit ->
              SandboxRunner.run_isolated(fn ->
                exit({:catastrophic_tool_bug, payload})
              end)

            :killed ->
              SandboxRunner.run_isolated(fn ->
                Process.exit(self(), :kill)
              end)

            :heap_oom ->
              # Set a tiny 10_000 word heap limit and allocate a large list to trigger BEAM :max_heap_size kill
              SandboxRunner.run_isolated(
                fn ->
                  Enum.to_list(1..500_000)
                end,
                max_heap_words: 10_000
              )

            :timeout ->
              SandboxRunner.run_isolated(
                fn ->
                  Process.sleep(200)
                end,
                timeout_ms: 20
              )

            :ok_value ->
              SandboxRunner.run_isolated(fn ->
                {:computed, payload}
              end)
          end

        # Caller process is still alive and healthy
        assert Process.alive?(caller_pid)

        case fault_kind do
          :raise_exception ->
            assert {:error, %{type: "tool_exception", reason: reason}} = result
            assert String.contains?(reason, payload)

          :throw_exit ->
            assert {:error, %{type: "tool_crash"}} = result

          :killed ->
            assert {:error, %{type: "resource_exhausted"}} = result

          :heap_oom ->
            assert {:error, %{type: "resource_exhausted"}} = result

          :timeout ->
            assert {:error, %{type: "tool_timeout"}} = result

          :ok_value ->
            assert {:ok, {:computed, ^payload}} = result
        end
      end
    end

    test "exec_command spills stdout exceeding spill_threshold_bytes to a temporary file and returns bounded preview" do
      # Generate ~60 KB of output with a low 8 KB spill threshold
      res =
        Local.exec_command(
          "sh",
          ["-c", "yes 'super_pi_beam_stream_line_0123456789' | head -n 2000"],
          spill_threshold_bytes: 8_192
        )

      assert {:ok, %{exit_code: 0, output: preview, spilled_path: spilled_path}} = res
      assert is_binary(spilled_path)
      assert File.exists?(spilled_path)
      assert String.contains?(preview, "Output exceeded 8192 bytes")

      spilled_bytes = File.stat!(spilled_path).size
      assert spilled_bytes > 50_000
      File.rm(spilled_path)
    end

    test "list_files and scan_lines respect .gitignore and locate matching lines accurately" do
      tmp_dir = Path.join(System.tmp_dir!(), "super_pi_scan_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(tmp_dir, "src"))
      File.mkdir_p!(Path.join(tmp_dir, "ignored_dir"))

      File.write!(Path.join(tmp_dir, ".gitignore"), "ignored_dir/\n*.secret\n")
      File.write!(Path.join(tmp_dir, "src/module_a.ex"), "defmodule Alpha do\n  def run_magic, do: :ok\nend\n")
      File.write!(Path.join(tmp_dir, "src/keys.secret"), "run_magic_secret\n")
      File.write!(Path.join(tmp_dir, "ignored_dir/skip.ex"), "run_magic\n")

      {:ok, files} = Local.list_files(tmp_dir)
      assert "src/module_a.ex" in files
      refute "src/keys.secret" in files
      refute "ignored_dir/skip.ex" in files

      {:ok, matches} = Local.scan_lines(tmp_dir, "run_magic")
      assert [%{path: "src/module_a.ex", line: 2, text: "  def run_magic, do: :ok"}] = matches

      File.rm_rf!(tmp_dir)
    end
  end
end
