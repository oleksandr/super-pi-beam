defmodule SuperPi.ProfilesIntegrationTest do
  use SuperPi.DataCase, async: false

  alias SuperPi.Conversation.Machine
  alias SuperPi.Durable.{Doc, Storage}
  alias SuperPi.Harness.Code
  alias SuperPi.Plugins.{Permissions, SlashCommands}
  alias SuperPi.TestSupport.Faults
  alias SuperPi.Plugins.Profiles, as: Workflow

  setup do
    dir = Path.join(System.tmp_dir!(), "workflow_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, ".agents"))
    File.write!(Path.join(dir, "AGENTS.md"), "REPOSITORY_RULE_SENTINEL")
    sentinel = Path.join(dir, "hook-ran")

    File.write!(
      Path.join(dir, ".agents/hooks.json"),
      Jason.encode!(%{
        "workflow-check" => %{
          "SessionStart" => [%{"type" => "command", "command" => "touch #{sentinel}"}]
        }
      })
    )

    on_exit(fn -> File.rm_rf(dir) end)

    agent =
      Code.agent_defaults(workspace_paths: [dir])
      |> Map.merge(%{
        "harness" => Code.id(),
        "globalConfigDir" => dir,
        "appDataDir" => dir,
        "workspaceApprovalScope" => "conversation"
      })

    %{agent: agent, dir: dir, sentinel: sentinel}
  end

  defp profile_input(input, ctx) do
    case SuperPi.Extension.run_on_input([SlashCommands, Workflow], input, ctx) do
      {:continue, text, media} -> {:transform, text, media}
      result -> result
    end
  end

  defp select!(agent, mode) do
    {:ok, selected} = Workflow.select(agent, mode)
    selected
  end

  test "workflow boundaries survive permission bypass flags and legacy mode changes", %{
    agent: agent,
    dir: dir
  } do
    for mode <- ["ask", "plan"] do
      config =
        select!(agent, mode)
        |> Map.merge(%{"executionMode" => "auto", "dangerouslySkipPermissions" => true})

      for {tool, args} <- [
            {"write", %{"path" => Path.join(dir, "file")}},
            {"bash", %{"command" => "pwd"}}
          ] do
        assert {:block, _} = Permissions.evaluate(tool, args, config, %{})
      end

      read = Permissions.evaluate("read", %{"path" => Path.join(dir, "file")}, config, %{})
      assert read == :allow
    end

    build = select!(agent, "build")
    assert :allow = Permissions.evaluate("write", %{"path" => Path.join(dir, "file")}, build, %{})
    assert {:prompt, _, _} = Permissions.evaluate("bash", %{"command" => "mix test"}, build, %{})

    assert :allow =
             Permissions.evaluate("bash", %{"command" => "mix test"}, build, %{
               "permissions" => %{"allow" => ["command(mix test)"]}
             })
  end

  test "Ask reads repository rules and skips mutating hooks, and switching restores tools without losing history",
       %{agent: agent, sentinel: sentinel} do
    conv = Storage.create_conversation!(agent: select!(agent, "ask"))
    me = self()

    responder = fn payload, _ ->
      send(me, {:payload, payload})
      {:ok, Faults.text_msg("answer")}
    end

    {:ok, pid} =
      Machine.start_link(
        conversation_id: conv.id,
        extensions: Code.extensions(),
        llm_responder: responder
      )

    assert {:ok, _} = Machine.submit(pid, "Supplied context: project uses OTP")
    assert_receive {:payload, ask}

    assert Enum.any?(ask.tools, &(&1["name"] == "read"))
    refute Enum.any?(ask.tools, &(&1["name"] in ["write", "edit", "bash"]))
    assert inspect(ask.system_sections) =~ "REPOSITORY_RULE_SENTINEL"
    assert inspect(ask.system_sections) =~ "cite file paths"

    refute File.exists?(sentinel)

    assert {:ok, :handled_by_extension} = Machine.submit(pid, "/workflow plan")
    assert {:ok, _} = Machine.submit(pid, "Compare two designs")
    assert_receive {:payload, plan}
    assert Enum.any?(plan.tools, &(&1["name"] == "read"))
    refute Enum.any?(plan.tools, &(&1["name"] in ["write", "edit", "bash"]))
    assert inspect(plan.system_sections) =~ "REPOSITORY_RULE_SENTINEL"
    assert inspect(plan.system_sections) =~ "compare designs"
    assert inspect(plan.system_sections) =~ "switch_mode"
    assert inspect(plan.messages) =~ "project uses OTP"
    refute File.exists?(sentinel)

    assert {:ok, :handled_by_extension} = Machine.submit(pid, "/workflow build")
    assert {:ok, _} = Machine.submit(pid, "Implement the chosen design")
    assert_receive {:payload, build}
    assert Enum.any?(build.tools, &(&1["name"] == "write"))
    assert Enum.any?(build.tools, &(&1["name"] == "bash"))
    assert inspect(build.system_sections) =~ "You are in Build"
    refute inspect(build.system_sections) =~ "You are in Plan"
    assert File.exists?(sentinel), "Build restores lifecycle hooks"

    assert {:ok, :handled_by_extension} = Machine.submit(pid, "/workflow ask")
    assert {:ok, _} = Machine.submit(pid, "Explain your previous answer")
    assert_receive {:payload, ask_again}

    assert Enum.any?(ask_again.tools, &(&1["name"] == "read"))
    refute Enum.any?(ask_again.tools, &(&1["name"] in ["write", "edit", "bash"]))
    refute inspect(ask_again.system_sections) =~ "CUSTOM_HOOK"
    GenServer.stop(pid)
  end

  test "tightening permissions cannot be undone by the active profile", %{agent: agent} do
    for changes <- [%{"executionMode" => "plan"}, %{"maxExecutionMode" => "plan"}] do
      conv = Storage.create_conversation!(agent: select!(agent, "build"))
      Storage.configure_agent!(conv.id, changes)
      config = Doc.snapshot("conversation", conv.id, "pi.agent")
      assert config["profile"] == "build"
      assert config["executionMode"] == "plan"
    end
  end

  test "unsolicited model calls cannot bypass Ask or Plan through profile enforcement", %{
    agent: agent
  } do
    me = self()

    for {mode, tool} <- [{"ask", "write"}, {"plan", "write"}] do
      conv = Storage.create_conversation!(agent: select!(agent, mode))

      {:ok, pid} =
        Machine.start_link(
          conversation_id: conv.id,
          extensions: [Permissions, Workflow],
          llm_responder: Faults.tool_then_text_responder(tool, %{}, "done"),
          tool_executor: fn name, _, _ ->
            send(me, {:executed, name})
            %{"output" => "unsafe"}
          end
        )

      assert {:ok, _} = Machine.submit(pid, "try a tool")
      refute_received {:executed, _}
      history = SuperPi.Durable.Context.derive(conv.id)
      assert inspect(history.messages) =~ "Blocked by extension"
      GenServer.stop(pid)
    end
  end

  test "Ask and Plan filter deferred and MCP tools by effects", %{agent: agent} do
    tools = [
      %{"name" => "mcp__docs__read", "effects" => ["net_read"]},
      %{"name" => "mcp__docs__write", "effects" => ["net_write"]},
      %{"name" => "unknown"},
      %{"name" => "tool_search"}
    ]

    config = agent |> Map.put("tools", tools) |> select!("plan")

    assert Enum.map(Workflow.offered_tools(tools, config), & &1["name"]) == [
             "mcp__docs__read",
             "tool_search"
           ]

    assert Workflow.offered_tools(tools, select!(config, "ask")) ==
             Workflow.offered_tools(tools, config)
  end

  test "slash selection is durable, rejects conflicts, and /plan enters Plan", %{agent: agent} do
    conv = Storage.create_conversation!(agent: agent)
    ctx = %{conversation_id: conv.id}
    assert :handled = profile_input("/workflow ask", ctx)
    assert :handled = profile_input("/mode auto", ctx)
    assert :handled = profile_input("/mode ask", ctx)
    assert {:error, _} = profile_input("/workflow invalid", ctx)
    assert Doc.snapshot("conversation", conv.id, "pi.agent")["profile"] == "ask"

    assert {:transform, "review this code", []} =
             profile_input("/plan review this code", ctx)

    assert Doc.snapshot("conversation", conv.id, "pi.agent")["profile"] == "plan"

    Storage.configure_agent!(conv.id, %{
      "executionMode" => "auto",
      "dangerouslySkipPermissions" => true
    })

    config = Doc.snapshot("conversation", conv.id, "pi.agent")
    assert config["executionMode"] == "plan"
    assert config["dangerouslySkipPermissions"] == false
  end
end
