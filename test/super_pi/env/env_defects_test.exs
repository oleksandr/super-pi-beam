defmodule SuperPi.Env.EnvDefectsTest do
  @moduledoc """
  Regression tests that reproduce env defects found in the code review
  (Env.Local, Env.FileLock, Env.SandboxRunner). Every test is expected to
  FAIL on the current code and pass once the matching finding is fixed.

  Run only these:  mix test --only known_bug
  Skip these:      mix test --exclude known_bug
  """
  use ExUnit.Case, async: false

  alias SuperPi.Env.{FileLock, Local, SandboxRunner}

  setup do
    dir = Path.join(System.tmp_dir!(), "env_defects_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  # Runs `fun` inside the lock server for `path`; returns the lock server pid.
  # Send `:release` to it to free the lock.
  defp hold_lock(path) do
    test = self()

    {:ok, _} =
      Task.start(fn ->
        FileLock.with_lock("defects", path, fn ->
          send(test, {:locked, self()})

          receive do
            :release -> :ok
          after
            10_000 -> :ok
          end
        end)
      end)

    assert_receive {:locked, lock_pid}, 2_000
    on_exit(fn -> send(lock_pid, :release) end)
    lock_pid
  end

  describe "Local.edit_file / write_file (env/local.ex:41-64)" do
    test "edit_file with empty old_text returns an error and leaves the file unchanged", %{dir: dir} do
      path = Path.join(dir, "f.txt")
      File.write!(path, "abc")

      result = Local.edit_file(path, "", "X")

      assert File.read!(path) == "abc", "file was corrupted: #{inspect(File.read!(path))}"
      assert {:error, _} = result
    end

    test "write_file replaces the file atomically (new inode via rename)", %{dir: dir} do
      path = Path.join(dir, "f.txt")
      File.write!(path, "old")
      %{inode: before_inode} = File.stat!(path)

      :ok = Local.write_file(path, "new content")

      %{inode: after_inode} = File.stat!(path)
      assert File.read!(path) == "new content"

      assert after_inode != before_inode,
             "file was truncated and rewritten in place; a crash mid-write loses data"
    end
  end

  describe "walk_dir follows symlinks (env/local.ex:187-213)" do
    test "a symlink cycle is not traversed by list_files", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, "a"))
      File.write!(Path.join([dir, "a", "real.txt"]), "x")
      :ok = File.ln_s(dir, Path.join([dir, "a", "loop"]))

      {:ok, files} = Local.list_files(dir)

      assert "a/real.txt" in files
      looped = Enum.filter(files, &String.contains?(&1, "loop"))
      assert looped == [], "recursed through the symlink cycle, got #{length(looped)} aliased paths"
    end
  end

  describe "gitignore matcher (env/local.ex:215-219)" do
    test "negation pattern re-includes a file", %{dir: dir} do
      File.write!(Path.join(dir, ".gitignore"), "*.log\n!keep.log\n")
      File.write!(Path.join(dir, "keep.log"), "k")
      File.write!(Path.join(dir, "drop.log"), "d")

      {:ok, files} = Local.list_files(dir)
      assert "keep.log" in files
      refute "drop.log" in files
    end

    test "leading-slash pattern only matches at the root", %{dir: dir} do
      File.write!(Path.join(dir, ".gitignore"), "/data\n")
      File.mkdir_p!(Path.join(dir, "data"))
      File.write!(Path.join([dir, "data", "root.txt"]), "r")
      File.mkdir_p!(Path.join([dir, "sub", "data"]))
      File.write!(Path.join([dir, "sub", "data", "nested.txt"]), "n")

      {:ok, files} = Local.list_files(dir)
      refute "data/root.txt" in files
      assert "sub/data/nested.txt" in files
    end

    test "nested .gitignore files are honoured", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, "sub"))
      File.write!(Path.join([dir, "sub", ".gitignore"]), "secret.txt\n")
      File.write!(Path.join([dir, "sub", "secret.txt"]), "s")
      File.write!(Path.join([dir, "sub", "ok.txt"]), "o")

      {:ok, files} = Local.list_files(dir)
      assert "sub/ok.txt" in files
      refute "sub/secret.txt" in files
    end

    test "** patterns match across directories", %{dir: dir} do
      File.write!(Path.join(dir, ".gitignore"), "docs/**/gen.txt\n")
      File.mkdir_p!(Path.join([dir, "docs", "a", "b"]))
      File.write!(Path.join([dir, "docs", "a", "b", "gen.txt"]), "g")
      File.write!(Path.join([dir, "docs", "a", "b", "keep.txt"]), "k")

      {:ok, files} = Local.list_files(dir)
      assert "docs/a/b/keep.txt" in files
      refute "docs/a/b/gen.txt" in files
    end
  end

  describe "FileLock (env/file_lock.ex:17-20,59-76)" do
    test "with_lock timeout returns {:error, :lock_timeout} instead of exiting the caller", %{dir: dir} do
      path = Path.join(dir, "locked.txt")
      hold_lock(path)

      outcome =
        try do
          FileLock.with_lock("defects", path, 100, fn -> :ran end)
        catch
          :exit, reason -> {:exit, reason}
        end

      assert outcome == {:error, :lock_timeout}
    end

    test "a symlink alias of a locked path is blocked by the same lock", %{dir: dir} do
      path = Path.join(dir, "real.txt")
      alias_path = Path.join(dir, "alias.txt")
      File.write!(path, "x")
      :ok = File.ln_s(path, alias_path)

      hold_lock(path)
      test = self()

      {:ok, _} =
        Task.start(fn ->
          FileLock.with_lock("defects", alias_path, fn -> send(test, :alias_ran) end)
        end)

      refute_receive :alias_ran, 300, "symlink alias acquired a different lock than the real path"
    end
  end

  describe "SandboxRunner spill file (env/sandbox_runner.ex:119-163)" do
    defp run_spill(dir, content, threshold \\ 10_000) do
      src = Path.join(dir, "big.txt")
      File.write!(src, content)

      {:ok, res} = SandboxRunner.exec_command("cat", [src], spill_threshold_bytes: threshold)
      assert is_binary(res.spilled_path), "expected output to spill"
      on_exit(fn -> File.rm(res.spilled_path) end)
      res
    end

    test "non-ASCII output round-trips byte-exact through the spill file", %{dir: dir} do
      content = String.duplicate("é", 20_000)
      res = run_spill(dir, content)

      md5 = fn bin -> Base.encode16(:crypto.hash(:md5, bin)) end
      assert md5.(File.read!(res.spilled_path)) == md5.(content), "spill file content differs from command output"
    end

    test "spill file is created with mode 0600", %{dir: dir} do
      res = run_spill(dir, String.duplicate("a", 20_000))

      %{mode: mode} = File.stat!(res.spilled_path)
      assert Bitwise.band(mode, 0o777) == 0o600
    end

    test "preview is valid UTF-8 even when the cut lands inside a codepoint", %{dir: dir} do
      # "a" shifts every 2-byte codepoint to an odd offset, so byte 16_384 splits one.
      res = run_spill(dir, "a" <> String.duplicate("é", 150_000), 200_000)

      assert String.valid?(res.output), "preview was cut in the middle of a UTF-8 codepoint"
    end
  end

  describe "SandboxRunner process handling (env/sandbox_runner.ex:27-57,91-117)" do
    test "a timed-out command and its grandchildren are killed" do
      n = 700_000 + :rand.uniform(99_999)
      marker = "sleep #{n}"
      on_exit(fn -> System.cmd("pkill", ["-f", marker]) end)

      result = SandboxRunner.exec_command("sh", ["-c", "#{marker} & wait"], timeout_ms: 300)
      assert {:error, %{type: "tool_timeout"}} = result

      survivors =
        Enum.reduce_while(1..10, nil, fn _, _ ->
          case System.cmd("pgrep", ["-f", marker]) do
            {_, 0} -> Process.sleep(100) && {:cont, :alive}
            _ -> {:halt, :gone}
          end
        end)

      assert survivors == :gone, "OS process `#{marker}` survived the timeout"
    end

    test "partial output is kept when the command exits non-zero" do
      {:ok, res} = SandboxRunner.exec_command("sh", ["-c", "echo partial-output; exit 3"])

      assert res.exit_code == 3
      assert res.output =~ "partial-output"
    end
  end

  describe "relative paths vs bash cd (env/local.ex, tools.ex:105,171)" do
    test "write honours the same `cd` argument as bash for relative paths", %{dir: dir} do
      rel = "cd_inconsistency_#{System.unique_integer([:positive])}.txt"
      on_exit(fn -> File.rm(Path.expand(rel)) end)

      bash = SuperPi.Tools.execute("bash", %{"command" => "pwd", "cd" => dir})
      assert String.trim(bash["output"]) |> Path.basename() == Path.basename(dir)

      SuperPi.Tools.execute("write", %{"path" => rel, "content" => "x", "cd" => dir})

      assert File.exists?(Path.join(dir, rel)),
             "relative write ignored `cd` and landed in the VM cwd: #{File.exists?(Path.expand(rel))}"
    end
  end
end
