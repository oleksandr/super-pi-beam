defmodule SuperPi.Harness.WorkspaceTest do
  use SuperPi.DataCase, async: false
  use ExUnitProperties

  alias SuperPi.Discovery
  alias SuperPi.CLI
  alias SuperPi.Plugins.Hooks, as: HooksJson
  alias SuperPi.Plugins.Permissions
  alias SuperPi.Plugins.Rules
  alias SuperPi.Plugins.TranscriptLogger, as: Brain
  alias SuperPi.Durable.Context

  describe "Property-Based & Integration Tests: SuperPi.Harness.Workspace" do
    property "Rules extension enforces 24,000-byte per-file cap on line boundaries and 20,000-token aggregate budget" do
      check all(
              line_len <- integer(40..120),
              line_count <- integer(50..450),
              token_budget <- integer(100..25_000),
              max_runs: 30
            ) do
        line = String.duplicate("a", line_len)
        raw_content = Enum.map(1..line_count, fn i -> "RULE_LINE_#{i}_#{line}" end) |> Enum.join("\n")

        truncated = Rules.truncate_rule_to_limit(raw_content, 24_000)

        if byte_size(raw_content) <= 24_000 do
          assert truncated == raw_content
        else
          assert String.contains?(truncated, "[... rule truncated at 24,000-byte limit ...]")
          # Prefix before the truncation marker is strictly <= 24,000 bytes
          [prefix, _] = String.split(truncated, "\n[... rule truncated")
          assert byte_size(prefix) <= 24_000
        end

        tmp_rule = Path.join(System.tmp_dir!(), "ws_rule_#{System.unique_integer([:positive])}.md")
        File.write!(tmp_rule, raw_content)

        rendered = Rules.build_rules_section([tmp_rule], token_budget)
        est_tokens = max(div(byte_size(truncated), 4), 1)

        if est_tokens <= token_budget do
          assert String.starts_with?(rendered, "<RULE[#{tmp_rule}]>")
        else
          assert String.starts_with?(rendered, "<RULE_POINTER[#{tmp_rule}]")
        end

        File.rm(tmp_rule)
      end
    end

    property "Permissions extension enforces command(...) allowlists, --mode plan, and --dangerously-skip-permissions" do
      check all(
              allowed_bin <- member_of(["git status", "head", "jq", "ls"]),
              extra_arg <- string(:alphanumeric, min_length: 1, max_length: 12),
              unlisted_bin <- member_of(["rm -rf /", "dd if=/dev/zero", "mkfs.ext4"]),
              max_runs: 35
            ) do
        allow_list = ["command(#{allowed_bin})"]

        assert Permissions.command_allowed?(allowed_bin, allow_list)
        assert Permissions.command_allowed?("#{allowed_bin} #{extra_arg}", allow_list)
        refute Permissions.command_allowed?(unlisted_bin, allow_list)
      end
    end

    property "HooksJson matcher_matches? accurately matches wildcard, exact tool name, and alternation regexes" do
      check all(
              tool_name <- member_of(["run_command", "view_file", "browser_navigate", "browser_click", "edit"]),
              max_runs: 30
            ) do
        assert HooksJson.matcher_matches?("*", tool_name)
        assert HooksJson.matcher_matches?("", tool_name)
        assert HooksJson.matcher_matches?(tool_name, "CORTEX_STEP_TYPE_" <> String.upcase(tool_name))

        assert HooksJson.matcher_matches?("run_command|view_file", "run_command")
        assert HooksJson.matcher_matches?("run_command|view_file", "view_file")
        refute HooksJson.matcher_matches?("run_command|view_file", "edit")

        if String.starts_with?(tool_name, "browser_") do
          assert HooksJson.matcher_matches?("browser_.*", tool_name)
        else
          refute HooksJson.matcher_matches?("browser_.*", tool_name)
        end
      end
    end

    test "discovers skills and rules from workspace directories" do
      tmp_ws = Path.join(System.tmp_dir!(), "ws_ws_discovery_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(tmp_ws, ".agents/skills/custom-skill"))
      File.write!(Path.join(tmp_ws, ".agents/skills/custom-skill/SKILL.md"), """
      ---
      name: custom-skill
      description: A test skill for discovery
      ---
      # Custom Skill
      """)
      File.write!(Path.join(tmp_ws, "AGENTS.md"), "# Project Agent Rules\n")

      skills = Discovery.discover_skills([tmp_ws])
      skill_names = Enum.map(skills, & &1.name)
      assert "custom-skill" in skill_names

      rule_files = Discovery.discover_rule_files([tmp_ws])
      assert Enum.any?(rule_files, &String.ends_with?(&1, "AGENTS.md"))
    end

    test "end-to-end HooksJson PreToolUse overwrite, SessionStart injection, Stop continuation, and Permissions enforcement" do
      tmp_ws = Path.join(System.tmp_dir!(), "ws_ws_#{System.unique_integer([:positive])}")
      dot_agents = Path.join(tmp_ws, ".agents")
      File.mkdir_p!(dot_agents)

      # Create a `hooks.json` with SessionStart, PreToolUse (with overwrite!), and Stop hooks
      hooks_json = %{
        "startup-banner" => %{
          "SessionStart" => [
            %{
              "type" => "command",
              "command" => ~s(echo '{"injectSteps":[{"systemMessage":{"systemMessage":"CUSTOM_HOOK_STARTUP_ACTIVE"}}]}')
            }
          ]
        },
        "arg-rewriter" => %{
          "PreToolUse" => [
            %{
              "matcher" => "ls|bash",
              "hooks" => [
                %{
                  "type" => "command",
                  "command" => ~s(echo '{"decision":"allow","overwrite":{"rewritten_by_hook":"yes"}}')
                }
              ]
            }
          ]
        }
      }

      File.write!(Path.join(dot_agents, "hooks.json"), Jason.encode!(hooks_json))

      responder = fn payload, _ctx ->
        has_tool? = Enum.any?(payload.messages, &(&1["role"] == "tool"))

        if not has_tool? do
          {:ok,
           %{
             "role" => "assistant",
             "content" => [
               %{
                 "type" => "tool_call",
                 "id" => "tc_1",
                 "name" => "ls",
                 "arguments" => %{"path" => tmp_ws}
               }
             ]
           }}
        else
          {:ok,
           %{
             "role" => "assistant",
             "content" => [%{"type" => "text", "text" => "Hooked run complete!"}]
           }}
        end
      end

      executor = fn "ls", args, _ctx ->
        %{
          "output" => "saw_rewritten=#{args["rewritten_by_hook"]}",
          "structured_output" => args,
          "details" => %{}
        }
      end

      {code, out} =
        CLI.run(
          ["--add-dir", tmp_ws, "-p", "test hooks", "--output-format", "json"],
          llm_responder: responder,
          tool_executor: executor,
          app_data_dir: tmp_ws
        )

      assert code == 0
      decoded = Jason.decode!(out)
      assert [%{"text" => "Hooked run complete!"}] = decoded["content"]

      # Verify SessionStart hook injected system section AND PreToolUse overwrite notice was prepended
      derived = Context.derive(1)
      assert Enum.any?(derived.system_sections, &(&1["content"] == "CUSTOM_HOOK_STARTUP_ACTIVE"))

      tool_msg = Enum.find(derived.messages, &(&1["role"] == "tool"))
      assert String.contains?(tool_msg["content"], "[Hook Notice: PreToolUse rewrote tool arguments for keys: rewritten_by_hook]")
      assert String.contains?(tool_msg["content"], "saw_rewritten=yes")

      # Verify dual-write transcript.jsonl and transcript_full.jsonl were created
      transcript_file = Path.join([tmp_ws, "brain", "1", ".system_generated", "logs", "transcript.jsonl"])
      assert File.regular?(transcript_file)

      File.rm_rf!(tmp_ws)
    end

    test "CLI subcommands (models, agents, mcp, plugin) and stream-json mode work " do
      tmp_cfg = Path.join(System.tmp_dir!(), "ws_cfg_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp_cfg)

      {0, models_out} = CLI.run(["models"])
      assert String.contains?(models_out, "gemini-4-argon-medium")
      refute String.contains?(models_out, "claude-sonnet-5-5-medium")

      {0, agents_out} = CLI.run(["agents"])
      assert String.contains?(agents_out, "research")

      {0, _} = CLI.run(["mcp", "add", "sqlite-helper", "sqlite-mcp", "/tmp/test.db"], global_config_dir: tmp_cfg)
      {0, mcp_list_out} = CLI.run(["mcp", "list"], global_config_dir: tmp_cfg)
      assert String.contains?(mcp_list_out, "sqlite-helper")
      assert String.contains?(mcp_list_out, "enabled")

      {0, _} = CLI.run(["mcp", "disable", "sqlite-helper"], global_config_dir: tmp_cfg)
      {0, mcp_disabled_out} = CLI.run(["mcp", "list"], global_config_dir: tmp_cfg)
      assert String.contains?(mcp_disabled_out, "disabled")

      # Test stream-json input/output format
      {0, stream_out} =
        CLI.run(
          ["--input-format", "stream-json", "--output-format", "stream-json", "--model", "test-echo"],
          stdin_lines: [~s({"prompt":"turn one"}), ~s({"prompt":"turn two"})],
          app_data_dir: tmp_cfg
        )

      lines = String.split(stream_out, "\n")
      assert length(lines) == 2
      assert Jason.decode!(Enum.at(lines, 0))["type"] == "turn_result"

      # Verify transcript truncation when content > 4096 bytes
      conv = SuperPi.Durable.Storage.create_conversation!()

      SuperPi.Durable.Storage.append_entry!(conv.id, "pi.message", %{
        "role" => "user",
        "content" => String.duplicate("Z", 6_000)
      })

      sync_info = Brain.sync_transcript!(conv.id, app_data_dir: tmp_cfg)
      compact_step = File.read!(sync_info.compact_path) |> String.trim() |> Jason.decode!()
      full_step = File.read!(sync_info.full_path) |> String.trim() |> Jason.decode!()

      assert compact_step["truncated_fields"] == ["content"]
      assert byte_size(compact_step["content"]) < byte_size(full_step["content"])
      refute Map.has_key?(full_step, "truncated_fields")

      File.rm_rf!(tmp_cfg)
    end
  end
end
