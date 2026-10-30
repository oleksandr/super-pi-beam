defmodule SuperPi.PluginsTest do
  use SuperPi.DataCase, async: false

  alias SuperPi.Plugins
  alias SuperPi.Plugins.{
    AutoCommit,
    ConfirmDestructive,
    CustomCompaction,
    GitCheckpoint,
    Handoff,
    InlineBash,
    JevRouter,
    PromptCustomizer,
    ProtectedPaths,
    Questionnaire,
    StructuredOutput,
    Subagent,
    Todo
  }
  alias SuperPi.Harness.{Autonomous, Interactive}
  alias SuperPi.Durable.Storage
  alias SuperPi.Durable.Schemas.Conversation

  setup do
    SuperPi.Tools.ensure_catalog_ets!()
    :ok
  end

  describe "Plugin Registry & Resolution" do
    test "lists and catalogs all 13 built-in plugins" do
      plugins = Plugins.list()
      assert length(plugins) == 13
      assert GitCheckpoint in plugins
      assert JevRouter in plugins
      assert Handoff in plugins
      assert ProtectedPaths in plugins
      assert InlineBash in plugins
      assert StructuredOutput in plugins
      assert Subagent in plugins
      assert Questionnaire in plugins
      assert CustomCompaction in plugins
      assert Todo in plugins
      assert PromptCustomizer in plugins

      catalog = Plugins.catalog()
      assert length(catalog) == 13
      assert Enum.all?(catalog, &(&1.id != nil and &1.name != nil and &1.description != nil))
    end

    test "resolves plugins by atom, string, alias, and declarative tuples" do
      assert Plugins.resolve(:protected_paths) == ProtectedPaths
      assert Plugins.resolve("protected-paths") == ProtectedPaths
      assert Plugins.resolve("jev-router") == JevRouter
      assert Plugins.resolve({:inline_bash, [timeout_ms: 5000]}) == {InlineBash, [timeout_ms: 5000]}
      assert Plugins.resolve({"subagent", [timeout_ms: 5000]}) == {Subagent, [timeout_ms: 5000]}

      resolved = Plugins.resolve_all([
        :protected_paths,
        "jev-router",
        {StructuredOutput, [terminating: true]},
        :unknown_plugin
      ])

      assert resolved == [ProtectedPaths, JevRouter, {StructuredOutput, [terminating: true]}]
    end
  end

  describe "ProtectedPaths Plugin" do
    test "allows safe paths and blocks protected files" do
      assert ProtectedPaths.before_tool("read", %{"path" => "lib/app.ex"}, %{}) == :allow
      assert ProtectedPaths.before_tool("write", %{"path" => "src/main.rs"}, %{}) == :allow

      assert {:block, msg1} = ProtectedPaths.before_tool("write", %{"path" => ".env"}, %{})
      assert msg1 =~ "path '.env' is protected"

      assert {:block, msg2} = ProtectedPaths.before_tool("edit", %{"path" => "config/.env.prod"}, %{})
      assert msg2 =~ "is protected"

      assert {:block, msg3} = ProtectedPaths.before_tool("read", %{"path" => ".git/config"}, %{})
      assert msg3 =~ "is protected"

      assert {:block, msg4} = ProtectedPaths.before_tool("write", %{"path" => "id_rsa"}, %{})
      assert msg4 =~ "is protected"
    end
  end

  describe "InlineBash Plugin" do
    test "ignores regular inputs without !{ patterns" do
      assert InlineBash.on_input("Hello there", %{}) == :continue
      assert InlineBash.on_input("!git status", %{}) == :continue
    end

    test "expands !{command} patterns in place" do
      input = "The answer is !{echo 42} and current dir contains !{echo ok}"
      assert {:transform, output, []} = InlineBash.on_input(input, %{workspace_root: File.cwd!()})
      assert output =~ "The answer is 42"
      assert output =~ "and current dir contains ok"
    end
  end

  describe "StructuredOutput Plugin" do
    test "registers tool and finishes turn with terminate: true" do
      {:ok, cfg} = StructuredOutput.before_agent_start(%{"tools" => []}, %{})
      assert Enum.any?(cfg["tools"], &(&1["name"] == "structured_output"))

      res = StructuredOutput.wrap_tool("structured_output", %{
        "headline" => "Security Audit",
        "summary" => "All checks passed cleanly.",
        "action_items" => ["Deploy to prod"]
      }, fn _ -> %{} end, %{})

      assert res["output"] =~ "Security Audit"
      assert res["control"] == %{"terminate" => true}
      assert res["structured_output"]["action_items"] == ["Deploy to prod"]
    end
  end

  describe "JevRouter Plugin" do
    test "routes to planning model initially, and cascades to implementation model after first edit" do
      # Planning phase: no edits yet
      messages_planning = [
        %{"role" => "user", "content" => "Inspect the codebase"},
        %{"role" => "assistant", "content" => [%{"type" => "tool_call", "name" => "read", "id" => "c1"}]},
        %{"role" => "tool", "name" => "read", "content" => "code"}
      ]

      assert JevRouter.determine_phase(messages_planning) == :planning

      {:ok, ctx_planning} = JevRouter.before_request(%{messages: messages_planning}, %{
        jev_opts: [planning_model: "gemini-2.5-pro", implementation_model: "gemini-2.5-flash"]
      })
      assert ctx_planning[:model] == "gemini-2.5-pro"
      assert ctx_planning[:jev_phase] == :planning

      # Implementation phase: edit tool has been called
      messages_implementation = messages_planning ++ [
        %{"role" => "assistant", "content" => [%{"type" => "tool_call", "name" => "edit", "id" => "c2"}]},
        %{"role" => "tool", "name" => "edit", "content" => "ok"}
      ]

      assert JevRouter.determine_phase(messages_implementation) == :implementation

      {:ok, ctx_impl} = JevRouter.before_request(%{messages: messages_implementation}, %{
        jev_opts: [planning_model: "gemini-2.5-pro", implementation_model: "gemini-2.5-flash"]
      })
      assert ctx_impl[:model] == "gemini-2.5-flash"
      assert ctx_impl[:jev_phase] == :implementation
    end
  end

  describe "Todo Plugin" do
    test "manages checklist actions on durable conversation document" do
      conv = Storage.create_conversation!()
      ctx = %{conversation_id: conv.id}

      # 1. Add todo
      res1 = Todo.wrap_tool("todo", %{"action" => "add", "text" => "Write tests"}, fn _ -> %{} end, ctx)
      assert res1["output"] =~ "Added todo #1"
      assert length(res1["structured_output"]["todos"]) == 1

      # 2. Add second todo
      res2 = Todo.wrap_tool("todo", %{"action" => "add", "text" => "Run dialyzer"}, fn _ -> %{} end, ctx)
      assert length(res2["structured_output"]["todos"]) == 2

      # 3. Toggle todo
      res3 = Todo.wrap_tool("todo", %{"action" => "toggle", "id" => 1}, fn _ -> %{} end, ctx)
      assert res3["output"] =~ "Toggled todo #1 to completed"

      # 4. List todos
      res4 = Todo.wrap_tool("todo", %{"action" => "list"}, fn _ -> %{} end, ctx)
      assert res4["output"] =~ "[x] #1: Write tests"
      assert res4["output"] =~ "[ ] #2: Run dialyzer"

      # 5. Clear completed
      res5 = Todo.wrap_tool("todo", %{"action" => "clear"}, fn _ -> %{} end, ctx)
      assert res5["output"] =~ "Cleared completed todos (remaining: 1)"
      assert length(res5["structured_output"]["todos"]) == 1
    end
  end

  describe "Questionnaire Plugin" do
    @questions [
      %{
        "question" => "Select storage backend",
        "options" => ["(Recommended) SQLite", "PostgreSQL"]
      }
    ]

    test "advertises the ask_question tool once" do
      {:ok, cfg} = Questionnaire.before_agent_start(%{"tools" => []}, %{})
      assert Enum.count(cfg["tools"], &(&1["name"] == "ask_question")) == 1

      {:ok, again} = Questionnaire.before_agent_start(cfg, %{})
      assert Enum.count(again["tools"], &(&1["name"] == "ask_question")) == 1
    end

    test "with no client able to answer, the call fails and never picks an answer itself" do
      res = Questionnaire.wrap_tool("ask_question", %{"questions" => @questions}, fn _ -> %{} end, %{conversation_id: 987_654})

      assert res["is_error"] == true
      assert res["structured_output"]["status"] == "no_interactive_client"
      refute res["output"] =~ "SQLite"
    end

    test "uses preset answers only when every question has one, and labels them" do
      res =
        Questionnaire.wrap_tool("ask_question", %{"questions" => @questions}, fn _ -> %{} end, %{
          questionnaire_answers: %{"Select storage backend" => "PostgreSQL"}
        })

      refute res["is_error"]
      assert res["structured_output"]["source"] == "override"
      assert res["output"] =~ "preset override, not asked): PostgreSQL"
    end
  end

  describe "PromptCustomizer Plugin" do
    test "adapts tool guidance dynamically based on active tools" do
      agent_cfg = %{
        "tools" => [
          %{"name" => "read"},
          %{"name" => "structured_output"}
        ],
        "systemSections" => [%{"id" => "core", "content" => "Base prompt"}]
      }

      {:ok, updated} = PromptCustomizer.before_agent_start(agent_cfg, %{})
      guidance = Enum.find(updated["systemSections"], &(&1["id"] == "tool_guidance"))
      assert guidance != nil
      assert guidance["content"] =~ "`read`: Use for file contents"
      assert guidance["content"] =~ "`structured_output`: Emit final machine-readable results"
      refute guidance["content"] =~ "`bash`"
    end
  end

  describe "CustomCompaction Plugin" do
    test "synthesizes structured milestone summary" do
      conv = Storage.create_conversation!()
      e1 = Storage.append_entry!(conv.id, "pi.message", %{"role" => "user", "content" => "Fix bug"})
      e2 = Storage.append_entry!(conv.id, "pi.message", %{
        "role" => "tool",
        "name" => "edit",
        "arguments" => %{"path" => "lib/app.ex"}
      })

      assert {:compacted, summary, meta} = CustomCompaction.before_compact(%{entries: [e1, e2], opts: []}, %{})
      assert summary =~ "## Context Compaction Summary"
      assert summary =~ "- Total conversation turns compressed: 2"
      assert summary =~ "- `lib/app.ex`"
      assert meta["strategy"] == "milestone_distillation"
    end
  end

  describe "Handoff Plugin" do
    test "creates child conversation with distilled prompt and terminates parent turn" do
      parent = Storage.create_conversation!()
      ctx = %{conversation_id: parent.id}

      res = Handoff.wrap_tool("handoff", %{
        "goal" => "Implement payment webhook",
        "summary" => "Database schemas created in previous session",
        "files" => ["lib/billing.ex"]
      }, fn _ -> %{} end, ctx)

      assert res["control"] == %{"terminate" => true}
      child_id = res["structured_output"]["child_conversation_id"]
      assert child_id != nil
      assert child_id != parent.id

      # Verify child conversation was created in storage
      child_conv = SuperPi.Repo.get!(Conversation, child_id)
      assert child_conv.parent_conversation_id == parent.id
    end
  end

  describe "Subagent Plugin" do
    test "does not advertise the delegate_subagent tool" do
      {:ok, cfg} = Subagent.before_agent_start(%{"tools" => []}, %{})
      refute Enum.any?(cfg["tools"], &(&1["name"] == "delegate_subagent"))
    end

    test "returns a not_implemented error instead of a fabricated success" do
      res =
        Subagent.wrap_tool("delegate_subagent", %{"role" => "scout", "prompt" => "Scan project dependencies"}, fn _ -> %{} end, %{})

      assert res["is_error"] == true
      assert res["structured_output"]["status"] == "not_implemented"
      refute res["output"] =~ "finished successfully"
    end
  end

  describe "Declarative Showcase Harnesses" do
    test "SuperPi.Harness.Autonomous resolves all composed plugins with options" do
      exts = Autonomous.extensions()
      mods = Enum.map(exts, fn {m, _} -> m; m -> m end)

      assert ProtectedPaths in mods
      assert ConfirmDestructive in mods
      assert GitCheckpoint in mods
      assert AutoCommit in mods
      assert JevRouter in mods
      assert Todo in mods
      assert PromptCustomizer in mods

      assert {ProtectedPaths, opts} = Enum.find(exts, &match?({ProtectedPaths, _}, &1))
      # Aliases and read tools were added by the security fix; the original three stay guarded.
      assert Enum.all?(["write", "edit", "read"], &(&1 in opts[:tools]))
      assert {ConfirmDestructive, cd_opts} = Enum.find(exts, &match?({ConfirmDestructive, _}, &1))
      # Shell aliases were added by the security fix; bash stays guarded.
      assert "bash" in cd_opts[:tools]
      assert {AutoCommit, [commit_prefix: "[super-pi-auto]", enabled: true]} in exts
      assert {JevRouter, [planning_model: "gemini-3.1-pro-preview", implementation_model: "gemini-3-flash-preview"]} in exts

      defaults = Autonomous.agent_defaults()
      assert defaults["effort"] == "high"
      assert defaults["executionMode"] == "auto"
    end

    test "SuperPi.Harness.Interactive resolves all composed plugins with options" do
      exts = Interactive.extensions()
      mods = Enum.map(exts, fn {m, _} -> m; m -> m end)

      assert Questionnaire in mods
      assert InlineBash in mods
      assert StructuredOutput in mods
      assert Handoff in mods
      assert Subagent in mods

      assert {InlineBash, [timeout_ms: 10_000, max_output_bytes: 8_192]} in exts
      assert {Subagent, [timeout_ms: 30_000]} in exts

      defaults = Interactive.agent_defaults()
      assert defaults["effort"] == "medium"
      assert defaults["executionMode"] == "interactive"
    end

    test "SuperPi.Harness.resolve resolves all harnesses" do
      assert SuperPi.Harness.resolve("super-pi-auto") == Autonomous
      assert SuperPi.Harness.resolve("super-pi-interactive") == Interactive
      assert SuperPi.Harness.resolve("auto") == Autonomous
      assert SuperPi.Harness.resolve("interactive") == Interactive
    end
  end

  describe "Plugin Configuration Injection via Extension Pipeline" do
    test "ProtectedPaths respects custom patterns passed via ctx[:config]" do
      # Normal path allowed by default
      assert ProtectedPaths.before_tool("write", %{"path" => "lib/custom.secret"}, %{}) == :allow

      # Blocked when custom pattern configured in ctx[:config]
      ctx = %{config: [patterns: [~r/\.secret$/]]}
      assert {:block, msg} = ProtectedPaths.before_tool("write", %{"path" => "lib/custom.secret"}, ctx)
      assert msg =~ "path 'lib/custom.secret' is protected"
    end

    test "SuperPi.Extension pipeline runner injects plugin options into ctx[:config]" do
      configured_ext = {ProtectedPaths, [patterns: [~r/locked_file\.txt$/]]}

      # Run before_tool through extension pipeline
      result = SuperPi.Extension.run_before_tool([configured_ext], "write", %{"path" => "locked_file.txt"}, %{})
      assert {:block, msg} = result
      assert msg =~ "path 'locked_file.txt' is protected"

      # Verify clean path is allowed
      assert {:allow, %{"path" => "normal.txt"}} =
               SuperPi.Extension.run_before_tool([configured_ext], "write", %{"path" => "normal.txt"}, %{})
    end

    test "JevRouter respects custom planning and implementation models via ctx[:config]" do
      ctx = %{config: [planning_model: "test-pro-model", implementation_model: "test-flash-model"]}

      # In planning phase
      assert {:ok, derived} = JevRouter.before_request(%{messages: []}, ctx)
      assert derived[:model] == "test-pro-model"
      assert derived[:jev_phase] == :planning

      # In implementation phase (after write tool call)
      edit_msg = %{"role" => "assistant", "content" => [%{"type" => "tool_call", "name" => "write"}]}
      assert {:ok, derived_impl} = JevRouter.before_request(%{messages: [edit_msg]}, ctx)
      assert derived_impl[:model] == "test-flash-model"
      assert derived_impl[:jev_phase] == :implementation
    end
  end
end
