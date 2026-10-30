defmodule SuperPi.Harness.WorkspaceMoreDefectsTest do
  @moduledoc """
  Regression tests that reproduce further Workspace harness defects found in the code
  review (hooks_json, discovery, brain, permissions, slash commands, harness
  module). Every test is expected to FAIL on the current code and pass once the
  matching finding is fixed.

  Run only these:  mix test --only known_bug
  Skip these:      mix test --exclude known_bug
  """
  use SuperPi.DataCase, async: false

  alias SuperPi.Durable.{Doc, Storage}
  alias SuperPi.Conversation.Machine
  alias SuperPi.Discovery
  alias SuperPi.Plugins.TranscriptLogger, as: Brain
  alias SuperPi.Plugins.Hooks, as: HooksJson
  alias SuperPi.Plugins.Permissions
  alias SuperPi.Plugins.SlashCommands
  alias SuperPi.TestSupport.Faults

  # --- helpers ---

  defp tmp_dir!(label, suffix \\ "") do
    dir =
      Path.join(
        System.tmp_dir!(),
        "ws_more_#{label}_#{System.unique_integer([:positive])}#{suffix}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp put_tmpdir!(dir) do
    old = System.get_env("TMPDIR")
    System.put_env("TMPDIR", dir)

    on_exit(fn ->
      if old, do: System.put_env("TMPDIR", old), else: System.delete_env("TMPDIR")
    end)
  end

  defp safe(fun) do
    {:ok, fun.()}
  rescue
    e -> {:raised, e}
  catch
    kind, reason -> {:caught, kind, reason}
  end

  defp payload, do: %{"toolCall" => %{"name" => "bash", "args" => %{"command" => "ls"}}}

  defp conversation!(agent), do: Storage.create_conversation!(agent: agent)

  # --- Finding 1: stdin redirect (hooks_json.ex:193) ---

  describe "hook stdin redirect (hooks_json.ex:193)" do
    test "compound command `cat > OUT; echo '{}'` receives the payload on stdin" do
      dir = tmp_dir!("redir")
      out = Path.join(dir, "out.json")

      _ =
        HooksJson.run_hook_command(
          %{"command" => "cat > #{out}; echo '{}'", "timeout" => 1},
          payload(),
          dir
        )

      assert File.read(out) == {:ok, Jason.encode!(payload())},
             "redirect bound only to the last command, cat read nothing"
    end

    test "a trailing # comment does not swallow the stdin redirect" do
      dir = tmp_dir!("comment")
      out = Path.join(dir, "out.json")

      _ =
        HooksJson.run_hook_command(
          %{"command" => "cat > #{out} # log payload", "timeout" => 1},
          payload(),
          dir
        )

      assert File.read(out) == {:ok, Jason.encode!(payload())}
    end

    test "a TMPDIR that contains a space does not break the hook" do
      dir = tmp_dir!("space", " with space")
      put_tmpdir!(dir)
      out = Path.join(tmp_dir!("spaceout"), "out.json")

      result =
        HooksJson.run_hook_command(%{"command" => "cat > #{out}", "timeout" => 1}, payload(), dir)

      assert File.read(out) == {:ok, Jason.encode!(payload())}, "got: #{inspect(result)}"
    end

    test "the stdin temp file is private (mode 0600) while the hook runs" do
      tdir = tmp_dir!("mode")
      put_tmpdir!(tdir)
      out = Path.join(tmp_dir!("modeout"), "ls.txt")

      cmd = "for f in #{tdir}/hook_in_*.json; do ls -l \"$f\" > #{out}; done; echo '{}'"
      script = Path.join(tdir, "hook.sh")
      File.write!(script, cmd <> "\n")

      _ =
        HooksJson.run_hook_command(
          %{"command" => "sh #{script}", "timeout" => 1},
          payload(),
          tdir
        )

      listing = File.read!(out)
      assert String.starts_with?(listing, "-rw-------"), "temp file mode: #{listing}"
    end
  end

  # --- Finding 2: timeout leaks process and temp file (hooks_json.ex:208) ---

  describe "hook timeout cleanup (hooks_json.ex:208)" do
    setup do
      tdir = tmp_dir!("timeout")
      put_tmpdir!(tdir)
      secs = 40_000 + rem(System.unique_integer([:positive]), 9_000)
      pattern = "sleep #{secs}"
      on_exit(fn -> System.cmd("pkill", ["-f", pattern]) end)

      result =
        HooksJson.run_hook_command(%{"command" => pattern, "timeout" => 1}, payload(), tdir)

      Process.sleep(100)
      assert result == {:error, :hook_timeout}
      %{tdir: tdir, pattern: pattern}
    end

    test "the child process does not survive the timeout", %{pattern: pattern} do
      {out, _} = System.cmd("pgrep", ["-f", pattern])
      assert String.trim(out) == "", "orphaned hook process(es): #{out}"
    end

    test "the stdin temp file is removed after the timeout", %{tdir: tdir} do
      assert Path.wildcard(Path.join(tdir, "hook_in_*.json")) == []
    end
  end

  # --- Finding 3: Stop loop and other hooks_json issues ---

  describe "Stop hook loop (hooks_json.ex:152-160)" do
    setup do
      Process.flag(:trap_exit, true)
      dir = tmp_dir!("stop")
      log = Path.join(dir, "stop.log")
      script = Path.join(dir, "stop.sh")

      File.write!(script, """
      cat >> #{log}
      echo >> #{log}
      echo '{"decision":"continue","reason":"again"}'
      """)

      hooks = Path.join(dir, "hooks.json")

      File.write!(
        hooks,
        Jason.encode!(%{"s" => %{"Stop" => [%{"command" => "sh #{script}", "timeout" => 1}]}})
      )

      conv =
        conversation!(%{"hooksFiles" => [hooks], "workspacePaths" => [dir], "appDataDir" => dir})

      {:ok, pid} =
        Machine.start_link(
          conversation_id: conv.id,
          extensions: [HooksJson],
          llm_responder: fn _p, _c -> {:ok, Faults.text_msg("done")} end
        )

      on_exit(fn -> Process.exit(pid, :kill) end)
      %{pid: pid, log: log}
    end

    test "an always-continuing Stop hook cannot loop forever", %{pid: pid} do
      result =
        try do
          Machine.submit(pid, "hi", timeout: 2_500)
        catch
          :exit, reason -> {:exit, reason}
        end

      Process.exit(pid, :kill)
      Process.sleep(150)
      assert {:ok, _} = result, "run did not end: #{inspect(result)}"
    end

    test "the second Stop payload carries stopHookActive: true", %{pid: pid, log: log} do
      _ =
        try do
          Machine.submit(pid, "hi", timeout: 1_500)
        catch
          :exit, reason -> {:exit, reason}
        end

      Process.exit(pid, :kill)
      Process.sleep(150)

      payloads =
        log
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      assert length(payloads) >= 2
      assert Enum.at(payloads, 1)["stopHookActive"] == true
    end
  end

  describe "other hooks_json defects" do
    test "PostInvocation hooks run in after_tools (moduledoc line 13)" do
      dir = tmp_dir!("postinv")
      marker = Path.join(dir, "ran")
      hooks = Path.join(dir, "hooks.json")

      File.write!(
        hooks,
        Jason.encode!(%{
          "p" => %{
            "PostInvocation" => [
              %{
                "command" =>
                  "touch #{marker}; echo '{\"terminationBehavior\":\"force_continue\"}'",
                "timeout" => 1
              }
            ]
          }
        })
      )

      conv =
        conversation!(%{"hooksFiles" => [hooks], "workspacePaths" => [dir], "appDataDir" => dir})

      _ = HooksJson.after_tools([%{"output" => "ok"}], %{conversation_id: conv.id})

      assert File.exists?(marker), "PostInvocation hook was never executed"
    end

    test "after_tool with is_error and a map output does not raise (hooks_json.ex:123)" do
      conv = conversation!(%{"hooksFiles" => [], "workspacePaths" => [File.cwd!()]})

      result =
        safe(fn ->
          HooksJson.after_tool("bash", %{}, %{"is_error" => true, "output" => %{"code" => 1}}, %{
            conversation_id: conv.id
          })
        end)

      assert {:ok, {:ok, _}} = result, "got: #{inspect(result)}"
    end

    test "non-JSON-encodable tool args do not raise in run_hook_command (hooks_json.ex:185)" do
      dir = tmp_dir!("enc")
      bad = %{"toolCall" => %{"name" => "bash", "args" => %{"x" => {:a, :tuple}}}}

      result =
        safe(fn ->
          HooksJson.run_hook_command(%{"command" => "echo '{}'", "timeout" => 1}, bad, dir)
        end)

      assert {:ok, {:error, _}} = result, "got: #{inspect(result)}"
    end
  end

  # --- Finding 4: Discovery manifests ---

  defp workspace!(label) do
    ws = tmp_dir!(label)
    File.mkdir_p!(Path.join(ws, ".git"))
    File.mkdir_p!(Path.join(ws, ".agents"))
    ws
  end

  defp write_skill!(dir, name, frontmatter \\ nil) do
    File.mkdir_p!(Path.join(dir, name))
    fm = frontmatter || "name: #{name}\ndescription: d"
    File.write!(Path.join([dir, name, "SKILL.md"]), "---\n#{fm}\n---\nbody\n")
  end

  defp discover(ws, manifest) do
    File.write!(
      Path.join([ws, ".agents", "skills.json"]),
      if(is_binary(manifest), do: manifest, else: Jason.encode!(manifest))
    )

    g = tmp_dir!("glob")
    a = tmp_dir!("app")
    Discovery.discover_skills([ws], global_config_dir: g, app_data_dir: a)
  end

  describe "malformed skills.json must not crash discovery (discovery.ex:143-160)" do
    @malformed [
      {"string entries", ~s({"entries": ["skills/x"]})},
      {"null inherits", ~s({"inherits": null})},
      {"null entries", ~s({"entries": null})},
      {"map entries", ~s({"entries": {"path": "x"}})},
      {"non-binary include_only", ~s({"entries": [{"path": "s", "include_only": [1]}]})},
      {"non-binary exclude", ~s({"entries": [{"path": "s", "exclude": [null]}]})},
      {"string inherits", ~s({"inherits": ["other.json"]})}
    ]

    for {label, json} <- @malformed do
      test "#{label}" do
        ws = workspace!("mal")
        write_skill!(Path.join(ws, "s"), "one")

        result = safe(fn -> discover(ws, unquote(json)) end)

        assert {:ok, list} = result
        assert is_list(list)
      end
    end
  end

  describe "include_only / exclude patterns (discovery.ex:287)" do
    test "alternation is anchored as a whole: exclude [\"draft|wip\"]" do
      ws = workspace!("alt")
      src = Path.join(ws, "src")
      for n <- ["draft", "wip", "draft-x", "old-wip"], do: write_skill!(src, n)

      names =
        ws
        |> discover(%{"entries" => [%{"path" => "src", "exclude" => ["draft|wip"]}]})
        |> Enum.map(& &1.name)
        |> Enum.sort()

      assert names == ["draft-x", "old-wip"]
    end

    test "glob patterns from the moduledoc work: exclude [\"*-test\"]" do
      ws = workspace!("glob")
      src = Path.join(ws, "src")
      for n <- ["a-test", "b"], do: write_skill!(src, n)

      names =
        ws
        |> discover(%{"entries" => [%{"path" => "src", "exclude" => ["*-test"]}]})
        |> Enum.map(& &1.name)

      assert names == ["b"]
    end

    test "a glob include_only selects matching dirs: [\"a-*\"]" do
      ws = workspace!("globinc")
      src = Path.join(ws, "src")
      for n <- ["a-one", "b-two"], do: write_skill!(src, n)

      names =
        ws
        |> discover(%{"entries" => [%{"path" => "src", "include_only" => ["a-*"]}]})
        |> Enum.map(& &1.name)

      assert names == ["a-one"]
    end
  end

  # --- Finding 5: parse_skill_md / path handling / dedupe ---

  describe "parse_skill_md frontmatter edge cases (discovery.ex:301-324)" do
    defp parse(frontmatter_file_content) do
      dir = tmp_dir!("skillmd")
      skill_dir = Path.join(dir, "dirname-skill")
      File.mkdir_p!(skill_dir)
      path = Path.join(skill_dir, "SKILL.md")
      File.write!(path, frontmatter_file_content)
      Discovery.parse_skill_md(path)
    end

    test "empty quoted name falls back to the directory name" do
      assert {:ok, %{name: "dirname-skill"}} = parse("---\nname: \"\"\ndescription: d\n---\nbody")
    end

    test "blank name falls back to the directory name" do
      assert {:ok, %{name: "dirname-skill"}} = parse("---\nname:\ndescription: d\n---\nbody")
    end

    test "single-quoted values are unquoted" do
      assert {:ok, %{name: "quoted"}} = parse("---\nname: 'quoted'\ndescription: d\n---\nbody")
    end

    test "an indented nested key does not shadow the top-level key" do
      assert {:ok, %{name: "top"}} =
               parse("---\nmetadata:\n  name: nested\nname: top\ndescription: d\n---\nbody")
    end

    test "plain multi-line continuation is kept" do
      assert {:ok, %{description: "first second"}} =
               parse("---\nname: n\ndescription: first\n  second\n---\nbody")
    end

    test "a leading BOM does not hide the frontmatter" do
      assert {:ok, %{name: "n"}} = parse("﻿---\nname: n\ndescription: d\n---\nbody")
    end

    test "empty-named skills do not collapse under uniq_by" do
      ws = workspace!("collapse")
      sk = Path.join([ws, ".agents", "skills"])
      write_skill!(sk, "one", "name: \"\"\ndescription: a")
      write_skill!(sk, "two", "name: \"\"\ndescription: b")

      names = ws |> discover(%{}) |> Enum.map(& &1.name) |> Enum.sort()
      assert names == ["one", "two"]
    end
  end

  describe "manifest path resolution (discovery.ex:296-299, 143)" do
    test "an empty entry path is ignored, not resolved to the manifest dir" do
      ws = workspace!("emptypath")
      write_skill!(Path.join(ws, ".agents"), "stray")

      names = ws |> discover(%{"entries" => [%{"path" => ""}]}) |> Enum.map(& &1.name)
      refute "stray" in names
    end

    test "repo_root fallback uses the repo of the manifest, not the last ancestor" do
      ws1 = workspace!("repo1")
      ws2 = workspace!("repo2")
      write_skill!(Path.join(ws1, "shared"), "from-ws1")

      File.write!(
        Path.join([ws1, ".agents", "skills.json"]),
        Jason.encode!(%{"entries" => [%{"path" => "shared"}]})
      )

      names =
        [ws1, ws2]
        |> Discovery.discover_skills(
          global_config_dir: tmp_dir!("g"),
          app_data_dir: tmp_dir!("a")
        )
        |> Enum.map(& &1.name)

      assert "from-ws1" in names
    end
  end

  describe "rule dedupe by canonical path (discovery.ex:74,353-360)" do
    test "two paths to one rules file through a symlinked directory are deduped" do
      ws = workspace!("dirlink")
      File.write!(Path.join(ws, "AGENTS.md"), "rule")
      global = Path.join(tmp_dir!("parent"), "global_link")
      File.ln_s!(ws, global)

      rules = Discovery.discover_rule_files([ws], global_config_dir: global)
      assert length(rules) == 1, "got: #{inspect(rules)}"
    end

    test "two paths to one rules file through a symlink chain are deduped" do
      ws = workspace!("chain")
      store = tmp_dir!("store")
      real = Path.join(store, "rules.md")
      File.write!(real, "rule")
      hop = Path.join(store, "hop.md")
      File.ln_s!(real, hop)
      File.ln_s!(hop, Path.join(ws, "AGENTS.md"))
      File.ln_s!(real, Path.join(ws, "GEMINI.md"))

      rules = Discovery.discover_rule_files([ws], global_config_dir: tmp_dir!("g"))
      assert length(rules) == 1, "got: #{inspect(rules)}"
    end
  end

  # --- Finding 6: Brain ---

  describe "Brain.plugin_validate (brain.ex:142-156)" do
    test "an unreadable plugin.json returns an error tuple" do
      dir = tmp_dir!("plugin")
      manifest = Path.join(dir, "plugin.json")
      File.write!(manifest, "{}")
      File.chmod!(manifest, 0o000)
      on_exit(fn -> File.chmod(manifest, 0o644) end)

      result = safe(fn -> Brain.plugin_validate(dir) end)
      assert {:ok, {:error, %{valid: false}}} = result, "got: #{inspect(result)}"
    end

    test "valid JSON that is not an object returns an error tuple" do
      dir = tmp_dir!("plugin")
      File.write!(Path.join(dir, "plugin.json"), "[]")

      result = safe(fn -> Brain.plugin_validate(dir) end)
      assert {:ok, {:error, %{valid: false}}} = result, "got: #{inspect(result)}"
    end
  end

  describe "Brain.mcp_list (brain.ex:54-58)" do
    for {label, servers} <- [
          {"server spec that is not a map", ~s({"mcpServers": {"a": "oops"}})},
          {"null args", ~s({"mcpServers": {"a": {"command": "x", "args": null}}})},
          {"non-list args", ~s({"mcpServers": {"a": {"command": "x", "args": "-y"}}})}
        ] do
      test "does not crash on #{label}" do
        g = tmp_dir!("mcp")
        File.write!(Path.join(g, "mcp_config.json"), unquote(servers))

        result = safe(fn -> Brain.mcp_list(global_config_dir: g) end)
        assert {:ok, list} = result
        assert is_list(list)
      end
    end
  end

  describe "Brain.sync_transcript! (brain.ex:183,40)" do
    test "re-exporting an unchanged conversation yields identical transcripts" do
      conv = Storage.create_conversation!()
      Storage.append_entry!(conv.id, "pi.message", %{"role" => "user", "content" => "hello"})
      app = tmp_dir!("brain")

      first = Brain.sync_transcript!(conv.id, app_data_dir: app)
      first_body = File.read!(first.full_path)
      Process.sleep(5)
      second = Brain.sync_transcript!(conv.id, app_data_dir: app)

      assert File.read!(second.full_path) == first_body,
             "created_at is export time, not entry time"
    end

    test "an empty conversation writes an empty transcript, not a lone newline" do
      conv = Storage.create_conversation!()
      res = Brain.sync_transcript!(conv.id, app_data_dir: tmp_dir!("brain"))

      assert File.read!(res.compact_path) == ""
    end
  end

  # --- Finding 7: Permissions / slash commands ---

  defp perms_conv!(extra) do
    base = %{"workspacePaths" => [File.cwd!()], "appDataDir" => tmp_dir!("appdata")}
    conversation!(Map.merge(base, extra))
  end

  describe "Permissions robustness (permissions.ex:48,105)" do
    test "a non-map `permissions` setting does not crash" do
      conv = perms_conv!(%{"settingsOverride" => %{"permissions" => "oops"}})

      result =
        safe(fn ->
          Permissions.before_tool("bash", %{"command" => "ls"}, %{conversation_id: conv.id})
        end)

      assert {:ok, _} = result, "got: #{inspect(result)}"
    end

    test "command_allowed? with a non-list allow does not raise" do
      assert safe(fn -> Permissions.command_allowed?("ls", "command(ls)") end) == {:ok, false}
    end

    test "command_allowed? with a non-binary command does not raise" do
      assert safe(fn -> Permissions.command_allowed?(nil, ["command(ls)"]) end) == {:ok, false}
    end

    test "workspace root `/` allows paths inside it" do
      conv =
        perms_conv!(%{
          "workspacePaths" => ["/"],
          "settingsOverride" => %{"allowNonWorkspaceAccess" => false}
        })

      assert :allow =
               Permissions.before_tool("read", %{"path" => "/etc/hosts"}, %{
                 conversation_id: conv.id
               })
    end
  end

  describe "SlashCommands (slash_commands.ex)" do
    setup do
      conv = conversation!(%{"executionMode" => "auto"})
      %{conv: conv}
    end

    defp mode(conv), do: Doc.snapshot("conversation", conv.id, "pi.agent")["executionMode"]

    test "/mode with an unknown value is rejected, not stored", %{conv: conv} do
      _ = SlashCommands.on_input("/mode foo", %{conversation_id: conv.id})
      assert mode(conv) == "auto", "stored executionMode #{inspect(mode(conv))}"
    end

    test "/plan does not permanently switch the conversation to plan mode", %{conv: conv} do
      _ = SlashCommands.on_input("/plan do it", %{conversation_id: conv.id})
      assert mode(conv) == "auto"
    end

    test "/goal enables goal verification (moduledoc line 8)", %{conv: conv} do
      _ = SlashCommands.on_input("/goal ship it", %{conversation_id: conv.id})
      agent = Doc.snapshot("conversation", conv.id, "pi.agent")

      assert agent["goal"] || agent["goalVerification"],
             "no goal state recorded: #{inspect(agent)}"
    end
  end

  # --- Finding 8: harness module drift ---

  describe "Code harness module" do
    test "extensions/0 matches CLI.default_extensions/0" do
      assert SuperPi.Harness.Code.extensions() == SuperPi.CLI.default_extensions()
    end
  end
end
