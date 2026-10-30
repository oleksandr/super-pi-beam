defmodule SuperPi.Plugins.SecurityDefectsTest do
  @moduledoc """
  Regression tests that reproduce plugin defects found in the code review
  (see vault note "20 - Codebase Review Findings"). Every test is expected to
  FAIL on the current code and pass once the matching finding is fixed.

  Run only these:  mix test --only known_bug
  Skip these:      mix test --exclude known_bug
  """
  use SuperPi.DataCase, async: false

  alias SuperPi.Harness.Code, as: CodeHarness
  alias SuperPi.Plugins.{
    AutoCommit,
    ConfirmDestructive,
    GitCheckpoint,
    Handoff,
    InlineBash,
    ProtectedPaths,
    Questionnaire,
    Subagent,
    Todo
  }


  # --- helpers ---

  defp autonomous_config(plugin) do
    Enum.find_value(CodeHarness.extensions(), fn
      {^plugin, opts} -> opts
      _ -> nil
    end) || []
  end

  defp tmp_dir!(label) do
    dir = Path.join(System.tmp_dir!(), "sp_#{label}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp git!(dir, args) do
    {out, code} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    {String.trim(out), code}
  end

  defp init_repo!(dir) do
    git!(dir, ["init", "-q", "-b", "main"])
    git!(dir, ["config", "user.email", "t@example.com"])
    git!(dir, ["config", "user.name", "Test"])
    git!(dir, ["config", "commit.gpgsign", "false"])
    File.write!(Path.join(dir, "base.txt"), "base\n")
    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "-q", "-m", "base"])
    dir
  end

  defp summary(text) do
    %{
      last_message: %{"role" => "assistant", "content" => [%{"type" => "text", "text" => text}]},
      conversation_id: 1
    }
  end

  # --- ProtectedPaths ---

  describe "ProtectedPaths bypasses (protected_paths.ex, harness/code.ex)" do
    test "Code harness config still guards the write_file/read_file/edit_file aliases" do
      cfg = autonomous_config(ProtectedPaths)

      for tool <- ~w(write_file read_file edit_file) do
        assert {:block, _} = ProtectedPaths.before_tool(tool, %{"path" => ".env"}, %{config: cfg}),
               "#{tool} on .env is allowed under the Code harness config"
      end
    end

    @read_style_bypasses [
      {"grep on .env", "grep", %{"path" => ".env", "pattern" => "KEY"}},
      {"search_files on .env", "search_files", %{"path" => ".env"}},
      {"ls on .git/", "ls", %{"dir" => ".git/"}},
      {"find on .git/", "find", %{"dir" => ".git/", "pattern" => "*"}},
      {"bash cat .env", "bash", %{"command" => "cat .env"}},
      {"bash redirect into .env", "bash", %{"command" => "echo X=1 > .env"}}
    ]

    for {label, tool, args} <- @read_style_bypasses do
      test "blocks #{label}" do
        assert {:block, _} = ProtectedPaths.before_tool(unquote(tool), unquote(Macro.escape(args)), %{config: []})
      end
    end

    @missing_patterns [".ssh/id_ed25519", ".npmrc", ".netrc", "tls/server.key", ".aws/config", ".git"]

    for path <- @missing_patterns do
      test "protects #{path}" do
        assert {:block, _} = ProtectedPaths.before_tool("write", %{"path" => unquote(path)}, %{config: []})
      end
    end

    for path <- [".ENV", "Config/.Env", "ID_RSA"] do
      test "protects case variant #{path} (case-insensitive file systems)" do
        assert {:block, _} = ProtectedPaths.before_tool("write", %{"path" => unquote(path)}, %{config: []})
      end
    end

    test "protects a symlink that points at a protected file" do
      dir = tmp_dir!("symlink")
      File.write!(Path.join(dir, ".env"), "SECRET=1\n")
      File.ln_s!(Path.join(dir, ".env"), Path.join(dir, "innocent.txt"))

      assert {:block, _} =
               ProtectedPaths.before_tool("read", %{"path" => Path.join(dir, "innocent.txt")}, %{config: []})
    end
  end

  # --- ConfirmDestructive ---

  describe "ConfirmDestructive bypasses (confirm_destructive.ex:16-22, harness/autonomous.ex:21)" do
    @destructive_variants [
      "rm -rfv /tmp/x",
      "rm -Rf /tmp/x",
      "rm -r -f /tmp/x",
      "rm --recursive --force /tmp/x",
      "git clean -fdx",
      "git clean -xdf",
      "git push --force origin main",
      "git push -f origin main",
      "find . -delete"
    ]

    for cmd <- @destructive_variants do
      test "blocks `#{cmd}`" do
        assert {:block, _} = ConfirmDestructive.before_tool("bash", %{"command" => unquote(cmd)}, %{config: []})
      end
    end

    test "Code harness config guards every shell tool alias, not only bash" do
      cfg = autonomous_config(ConfirmDestructive)

      for tool <- ~w(sh terminal run_command exec) do
        assert {:block, _} =
                 ConfirmDestructive.before_tool(tool, %{"command" => "rm -rf /tmp/x"}, %{config: cfg}),
               "#{tool} runs rm -rf unguarded under the Code harness config"
      end
    end
  end

  # --- plugin config shape ---

  describe "plugins crash when config is a map (Plugins.resolve/1 accepts maps; plugins call Keyword.get)" do
    test "ProtectedPaths" do
      assert :allow = ProtectedPaths.before_tool("write", %{"path" => "a.txt"}, %{config: %{}})
    end

    test "ConfirmDestructive" do
      assert :allow = ConfirmDestructive.before_tool("bash", %{"command" => "ls"}, %{config: %{}})
    end

    test "InlineBash" do
      assert {:transform, out, []} = InlineBash.on_input("x !{echo hi}", %{config: %{timeout_ms: 2_000}})
      assert out =~ "hi"
    end

    test "Subagent" do
      res =
        Subagent.wrap_tool("delegate_subagent", %{"role" => "scout", "prompt" => "look"}, fn _ -> %{} end, %{
          config: %{timeout_ms: 2_000}
        })

      assert is_map(res)
    end
  end

  # --- AutoCommit ---

  describe "AutoCommit (auto_commit.ex:35-67)" do
    @describetag :tmp_dir

    test "uses the assistant's last message in the commit subject", %{tmp_dir: _} do
      dir = init_repo!(tmp_dir!("ac_msg"))
      File.write!(Path.join(dir, "feature.txt"), "x\n")

      AutoCommit.after_run(summary("Implemented feature X"), %{workspace_root: dir, config: [commit_prefix: "[t]"]})

      {subject, 0} = git!(dir, ["log", "-1", "--format=%s"])
      assert subject =~ "Implemented feature X", "commit subject was: #{subject}"
    end

    test "does not conclude a merge that has conflicts" do
      dir = init_repo!(tmp_dir!("ac_merge"))
      File.write!(Path.join(dir, "c.txt"), "one\n")
      git!(dir, ["add", "-A"])
      git!(dir, ["commit", "-q", "-m", "c1"])
      git!(dir, ["checkout", "-q", "-b", "other"])
      File.write!(Path.join(dir, "c.txt"), "other side\n")
      git!(dir, ["commit", "-q", "-am", "other change"])
      git!(dir, ["checkout", "-q", "main"])
      File.write!(Path.join(dir, "c.txt"), "main side\n")
      git!(dir, ["commit", "-q", "-am", "main change"])
      {_out, code} = git!(dir, ["merge", "other"])
      assert code != 0, "precondition: merge must conflict"
      assert {_, 0} = git!(dir, ["rev-parse", "-q", "--verify", "MERGE_HEAD"])

      AutoCommit.after_run(summary("done"), %{workspace_root: dir, config: []})

      assert {_, 0} = git!(dir, ["rev-parse", "-q", "--verify", "MERGE_HEAD"]),
             "auto-commit concluded the merge and committed conflict markers"
    end

    test "never commits an unignored .env file" do
      dir = init_repo!(tmp_dir!("ac_env"))
      File.write!(Path.join(dir, ".env"), "API_KEY=secret\n")
      File.write!(Path.join(dir, "code.txt"), "ok\n")

      AutoCommit.after_run(summary("done"), %{workspace_root: dir, config: []})

      {tracked, 0} = git!(dir, ["ls-files"])
      refute ".env" in String.split(tracked, "\n"), "secret file was committed"
    end
  end

  # --- GitCheckpoint ---

  describe "GitCheckpoint (git_checkpoint.ex:30-35)" do
    test "keeps the checkpoint reachable so a rollback is possible" do
      dir = init_repo!(tmp_dir!("gc"))
      File.write!(Path.join(dir, "base.txt"), "modified by user\n")

      GitCheckpoint.before_tool("write", %{"path" => "base.txt"}, %{workspace_root: dir, conversation_id: 1})

      {refs, 0} = git!(dir, ["for-each-ref", "--format=%(refname)"])
      {stashes, 0} = git!(dir, ["stash", "list"])

      checkpoint_refs =
        refs
        |> String.split("\n", trim: true)
        |> Enum.reject(&String.starts_with?(&1, "refs/heads/"))

      assert checkpoint_refs != [] or stashes != "",
             "`git stash create` output was only logged; the dangling commit is garbage-collected"
    end
  end

  # --- InlineBash ---

  describe "InlineBash (inline_bash.ex:59-86)" do
    test "a command containing } is not cut at the first brace" do
      {:transform, out, []} = InlineBash.on_input("!{echo ${UNSET_VAR_X:-ok}}", %{workspace_root: File.cwd!(), config: []})

      refute out =~ "failed with code", "command was truncated at the first }: #{out}"
      assert out =~ "ok"
    end

    test "truncation never splits a UTF-8 character" do
      {:transform, out, []} =
        InlineBash.on_input("!{printf 'ééééé'}", %{workspace_root: File.cwd!(), config: [max_output_bytes: 3]})

      assert String.valid?(out), "output is not valid UTF-8: #{inspect(out)}"
    end

    test "a timed-out command leaves no orphan OS process" do
      marker = "#{System.unique_integer([:positive]) + 900_000}"
      on_exit(fn -> System.cmd("pkill", ["-f", "sleep #{marker}"], stderr_to_stdout: true) end)

      InlineBash.on_input("!{sleep #{marker}}", %{workspace_root: File.cwd!(), config: [timeout_ms: 200]})
      Process.sleep(300)

      {out, _} = System.cmd("pgrep", ["-f", "sleep #{marker}"], stderr_to_stdout: true)
      assert String.trim(out) == "", "orphaned `sleep #{marker}` is still running (pids: #{String.trim(out)})"
    end
  end

  # --- Subagent ---

  describe "Subagent (subagent.ex)" do
    test "a child that fails is reported as failed, never as a success" do
      Application.put_env(:super_pi, :subagent_machine_opts, llm_responder: fn _p, _c -> {:error, "provider down"} end)
      on_exit(fn -> Application.delete_env(:super_pi, :subagent_machine_opts) end)

      conv = SuperPi.Durable.Storage.create_conversation!()
      {:ok, task} = SuperPi.Durable.TaskEngine.create_task(conv.id, "pi.generation")
      {:ok, running} = SuperPi.Durable.TaskEngine.start_task(task.id)

      res =
        Subagent.wrap_tool("delegate_subagent", %{"role" => "reviewer", "prompt" => "audit the repo"}, fn _ -> %{} end, %{
          conversation_id: conv.id,
          active_task_id: running.id
        })

      assert [%{"task_id" => task_id}] = res["structured_output"]["subagents"]
      Oban.drain_queue(queue: :subagents)

      child = SuperPi.Durable.TaskEngine.get_task(task_id)
      assert child.status == "failed"
      assert child.result["error"] =~ "provider down"
    end
  end

  # --- malformed tool arguments ---

  describe "plugins crash the machine on malformed tool arguments (finding 8)" do
    setup do
      conv = SuperPi.Durable.Storage.create_conversation!()
      %{ctx: %{conversation_id: conv.id}}
    end

    test "Questionnaire with a string instead of a list of questions", %{ctx: ctx} do
      assert is_map(Questionnaire.wrap_tool("ask_question", %{"questions" => "oops"}, fn _ -> %{} end, ctx))
    end

    test "Questionnaire with a question entry that is not a map", %{ctx: ctx} do
      assert is_map(Questionnaire.wrap_tool("ask_question", %{"questions" => ["just text"]}, fn _ -> %{} end, ctx))
    end

    test "Questionnaire with options that are not a list", %{ctx: ctx} do
      args = %{"questions" => [%{"question" => "q?", "options" => "yes"}]}
      assert is_map(Questionnaire.wrap_tool("ask_question", args, fn _ -> %{} end, ctx))
    end

    test "Handoff with files as a string", %{ctx: ctx} do
      args = %{"goal" => "g", "summary" => "s", "files" => "a.ex"}
      assert is_map(Handoff.wrap_tool("handoff", args, fn _ -> %{} end, ctx))
    end

    test "Todo with args that are not a map", %{ctx: ctx} do
      assert is_map(Todo.wrap_tool("todo", "oops", fn _ -> %{} end, ctx))
    end

    test "Todo toggling an unknown id reports an error", %{ctx: ctx} do
      res = Todo.wrap_tool("todo", %{"action" => "toggle", "id" => 999}, fn _ -> %{} end, ctx)
      assert res["is_error"] == true, "toggle of a missing id reported success: #{inspect(res)}"
    end
  end
end
