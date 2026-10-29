defmodule SuperPi.Harness.AgyCliDefectsTest do
  @moduledoc """
  Regression tests that reproduce defects in `SuperPi.Harness.AGY.CLI` found in
  the code review. Every test is expected to FAIL on the current code and pass
  once the matching finding is fixed. The CLI is driven in-process through
  `CLI.run/2` with temp `global_config_dir` and `app_data_dir` options.

  Run only these:  mix test --only known_bug
  Skip these:      mix test --exclude known_bug
  """
  use SuperPi.DataCase, async: false

  alias SuperPi.Conversation.Machine
  alias SuperPi.Durable.{Doc, Storage}
  alias SuperPi.Harness.AGY.CLI
  alias SuperPi.TestSupport.Faults

  @moduletag :known_bug

  setup do
    Process.flag(:trap_exit, true)
    g = tmp_dir!("global")
    a = tmp_dir!("app")
    %{g: g, a: a, opts: [global_config_dir: g, app_data_dir: a]}
  end

  defp tmp_dir!(label) do
    dir = Path.join(System.tmp_dir!(), "agy_cli_#{label}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp safe(fun) do
    {:ok, fun.()}
  rescue
    e -> {:raised, e}
  catch
    kind, reason -> {:caught, kind, reason}
  end

  defp text_responder(text \\ "ok"), do: fn _p, _c -> {:ok, Faults.text_msg(text)} end

  defp session_opts(opts, extra \\ []) do
    Keyword.merge([extensions: [], llm_responder: text_responder()] ++ opts, extra)
  end

  # --- MCP / plugin subcommands ---

  describe "mcp and plugin subcommands (cli.ex:309-311, 270-290)" do
    test "`mcp enable` of an unknown server does not crash and fails", %{opts: opts} do
      result = safe(fn -> CLI.run(["mcp", "enable", "typo"], opts) end)
      assert {:ok, {code, _out}} = result, "got: #{inspect(result)}"
      assert code != 0
    end

    test "`mcp disable` of an unknown server does not crash and fails", %{opts: opts} do
      result = safe(fn -> CLI.run(["mcp", "disable", "typo"], opts) end)
      assert {:ok, {code, _out}} = result, "got: #{inspect(result)}"
      assert code != 0
    end

    test "`mcp remove` of a missing name does not claim success", %{opts: opts} do
      {code, out} = CLI.run(["mcp", "remove", "ghost"], opts)
      refute code == 0 and out =~ "Removed", "got: #{inspect({code, out})}"
    end

    test "`plugin enable` of a non-existent plugin fails and writes no config", %{opts: opts, g: g} do
      {code, _out} = CLI.run(["plugin", "enable", "ghost"], opts)
      assert code != 0
      refute File.exists?(Path.join(g, "config.json"))
    end

    test "`plugin disable` of a non-existent plugin fails and writes no config", %{opts: opts, g: g} do
      {code, _out} = CLI.run(["plugin", "disable", "ghost"], opts)
      assert code != 0
      refute File.exists?(Path.join(g, "config.json"))
    end
  end

  # --- Argument parsing ---

  describe "argument parsing (cli.ex:61-97, 291-297)" do
    test "`mcp add` keeps dash-prefixed server args", %{opts: opts, g: g} do
      CLI.run(["mcp", "add", "fs", "npx", "-y", "@scope/server"], opts)

      cfg = g |> Path.join("mcp_config.json") |> File.read!() |> Jason.decode!()
      assert cfg["mcpServers"]["fs"]["args"] == ["-y", "@scope/server"]
    end

    test "a prompt containing a --word is not truncated" do
      assert {:run, _flags, pos} = CLI.parse_args(["explain", "the", "--foo", "flag"])
      assert Enum.join(pos, " ") == "explain the --foo flag"
    end

    for word <- ["help", "agent", "models", "mcp", "plugin"] do
      test "a prompt starting with `#{word}` is a prompt, not a subcommand" do
        assert {:run, _flags, _pos} = CLI.parse_args([unquote(word), "me", "with", "this"])
      end
    end

    test "`--agent research` restricts the session tools to read-only tools", %{opts: opts} do
      conv = Storage.create_conversation!()
      CLI.run(["--conversation", "#{conv.id}", "--agent", "research", "-p", "hi"], session_opts(opts))

      tools = Doc.snapshot("conversation", conv.id, "pi.agent")["tools"] || []
      names = Enum.map(tools, & &1["name"])
      mutating = names -- ["read", "grep", "find", "ls", "tool_search"]

      assert mutating == [], "research agent still has: #{inspect(mutating)}"
    end

    test "`--agent research` is recorded in the agent config", %{opts: opts} do
      conv = Storage.create_conversation!()
      CLI.run(["--conversation", "#{conv.id}", "--agent", "research", "-p", "hi"], session_opts(opts))

      assert Doc.snapshot("conversation", conv.id, "pi.agent")["agent"] == "research"
    end
  end

  # --- Interactive TUI launch ---

  describe "launch_interactive_tui (cli.ex:238-241)" do
    setup do
      cwd = File.cwd!()
      on_exit(fn -> File.cd!(cwd) end)
      repo = tmp_dir!("untrusted")
      File.mkdir_p!(Path.join(repo, "bin"))
      conv = Storage.create_conversation!()
      flags = %{model: nil, effort: nil, mode: nil, prompt_interactive: nil}
      %{repo: repo, conv: conv, flags: flags}
    end

    test "does not execute bin/agy-tui from the current directory", %{repo: repo, conv: conv, flags: flags} do
      marker = Path.join(repo, "pwned")
      bin = Path.join(repo, "bin/agy-tui")
      File.write!(bin, "#!/bin/sh\ntouch #{marker}\n")
      File.chmod!(bin, 0o755)
      File.cd!(repo)

      _ = safe(fn -> CLI.launch_interactive_tui(conv.id, flags, [repo], []) end)

      refute File.exists?(marker), "executed a binary from the untrusted working directory"
    end
  end

  # --- Machine lifecycle ---

  describe "machine ownership and cleanup (cli.ex:231, 198)" do
    test "a run does not stop a machine it did not start", %{opts: opts} do
      conv = Storage.create_conversation!()

      {:ok, owner} =
        Machine.start_link(conversation_id: conv.id, extensions: [], llm_responder: text_responder("owner"))

      _ = safe(fn -> CLI.run(["--conversation", "#{conv.id}", "-p", "hi"], session_opts(opts)) end)

      assert Process.alive?(owner), "CLI stopped a machine owned by another caller"
    end

    test "a raise during the run does not leak the linked machine", %{g: g} do
      conv = Storage.create_conversation!()
      not_a_dir = Path.join(tmp_dir!("leak"), "file")
      File.write!(not_a_dir, "x")
      opts = session_opts(global_config_dir: g, app_data_dir: not_a_dir)

      result = safe(fn -> CLI.run(["--conversation", "#{conv.id}", "-p", "hi"], opts) end)

      assert match?({:raised, _}, result) or match?({:caught, _, _}, result) or match?({:ok, {1, _}}, result)
      assert Registry.lookup(SuperPi.Registry, {:conversation_machine, conv.id}) == [], "machine leaked"
    end
  end

  # --- stream-json input ---

  describe "stream-json turns (cli.ex:384)" do
    defp stream(opts, lines, responder) do
      conv = Storage.create_conversation!()
      all = session_opts(opts, llm_responder: responder, stdin_lines: lines)
      safe(fn -> CLI.run(["--conversation", "#{conv.id}", "--input-format", "stream-json"], all) end)
    end

    test "a failed turn does not crash the whole run", %{opts: opts} do
      result = stream(opts, [~s({"prompt":"a"})], fn _p, _c -> {:error, :boom} end)
      assert {:ok, {_code, _out}} = result, "got: #{inspect(result)}"
    end

    test "blank stdin lines are not submitted as prompts", %{opts: opts} do
      me = self()

      responder = fn _p, _c ->
        send(me, :responder_called)
        {:ok, Faults.text_msg("ok")}
      end

      _ = stream(opts, ["", "   "], responder)
      refute_received :responder_called
    end

    test "a non-string prompt does not crash the run", %{opts: opts} do
      result = stream(opts, [~s({"prompt": 5})], text_responder())
      assert {:ok, {_code, _out}} = result, "got: #{inspect(result)}"
    end
  end

  # --- remote-control ---

  describe "remote-control status (cli.ex:161-173)" do
    test "status does not report ready when no server is running" do
      {_code, out} = CLI.run(["remote-control", "status"])
      refute Jason.decode!(out)["status"] == "ready"
    end
  end
end
