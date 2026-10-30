defmodule SuperPi.Plugins.PermissionPromptTest do
  @moduledoc """
  A blocked tool call can ask a human. The property that matters is fail-closed: with no client to
  ask, or a prompt that ends in anything but a clear yes, the result is the block that earlier
  releases returned, with the same message.
  """
  use SuperPi.DataCase, async: false

  alias SuperPi.Conversation.Machine
  alias SuperPi.Durable.{Doc, Storage}
  alias SuperPi.Extension
  alias SuperPi.Plugins.{Hooks, Permissions}
  alias SuperPi.TestSupport.Faults
  alias SuperPi.UI.Broker

  @blocked "Tool `mcp__x__y` is not allowed by default in mode `accept-edits`."

  setup do
    saved = Application.fetch_env(:super_pi, :permissions)
    Application.delete_env(:super_pi, :permissions)

    on_exit(fn ->
      case saved do
        {:ok, v} -> Application.put_env(:super_pi, :permissions, v)
        :error -> Application.delete_env(:super_pi, :permissions)
      end
    end)

    app = Path.join(System.tmp_dir!(), "pp_#{System.unique_integer([:positive])}")
    File.mkdir_p!(app)
    on_exit(fn -> File.rm_rf(app) end)

    tool = %{"name" => "mcp__x__y", "effects" => ["net_write"]}
    conv = Storage.create_conversation!(agent: %{"executionMode" => "accept-edits", "workspacePaths" => [File.cwd!()], "appDataDir" => app, "tools" => [tool]})
    {:ok, conv: conv, app: app}
  end

  # Runs the pipeline of a tool call the way the machine does: before_tool, then wrap_tool.
  defp call(conv, tool, args, tool_call_id \\ "call_1") do
    exts = [Permissions]
    ctx = %{conversation_id: conv.id, tool_call_id: tool_call_id, turn_id: 1}

    case Extension.run_before_tool(exts, tool, args, ctx) do
      {:block, reason} -> {:blocked_early, reason}
      {:allow, final} -> Extension.run_wrap_tool(exts, tool, final, fn _ -> %{"output" => "ran"} end, ctx)
    end
  end

  describe "fail closed" do
    test "no client: the block is byte-identical to what earlier releases returned", %{conv: conv} do
      assert {:blocked_early, @blocked} = call(conv, "mcp__x__y", %{})

      assert {:blocked_early, "Command `make x` is not in `permissions.allow` under mode `accept-edits`."} =
               call(conv, "bash", %{"command" => "make x"})
    end

    test "the kill switch keeps the block even with a client", %{conv: conv} do
      Application.put_env(:super_pi, :permissions, interactive_prompts: false)
      Broker.register_responder(conv.id)
      assert {:blocked_early, @blocked} = call(conv, "mcp__x__y", %{})
    end

    test "a client that answers nothing readable, or times out, ends in the same block", %{conv: conv} do
      Application.put_env(:super_pi, :permission_prompt_timeout_ms, 50)
      on_exit(fn -> Application.delete_env(:super_pi, :permission_prompt_timeout_ms) end)
      Broker.register_responder(conv.id)
      assert %{"is_error" => true, "output" => "Blocked by extension: " <> @blocked} = call(conv, "mcp__x__y", %{})
    end

    test "an unreadable answer is a block", %{conv: conv} do
      Broker.register_responder(conv.id)
      Phoenix.PubSub.subscribe(SuperPi.PubSub, "conversation:#{conv.id}")
      task = Task.async(fn -> call(conv, "mcp__x__y", %{}) end)
      assert_receive {:conversation_event, _, %{"type" => "permission_request", "request_id" => rid}}
      Broker.respond(rid, "maybe")
      assert %{"is_error" => true} = Task.await(task)
    end

    test "modes that must never be promptable stay blocks before any tool runs", %{conv: conv, app: app} do
      Broker.register_responder(conv.id)
      assert {:blocked_early, "Path access outside trusted workspaces" <> _} = call(conv, "read", %{"path" => "/etc/passwd"})

      plan = Storage.create_conversation!(agent: %{"executionMode" => "plan", "workspacePaths" => [File.cwd!()], "appDataDir" => app})
      Broker.register_responder(plan.id)
      assert {:blocked_early, "Tool `write` is blocked in `--mode plan`" <> _} = call(plan, "write", %{"path" => "x", "content" => "y"})

      Storage.configure_agent!(conv.id, %{"settingsOverride" => %{"permissions" => %{"deny" => ["command(rm)"]}}})
      assert {:blocked_early, "Command is blocked by `permissions.deny`."} = call(conv, "bash", %{"command" => "rm x"})
    end
  end

  describe "with a client" do
    setup %{conv: conv} do
      Broker.register_responder(conv.id)
      Phoenix.PubSub.subscribe(SuperPi.PubSub, "conversation:#{conv.id}")
      :ok
    end

    defp answer(option) do
      assert_receive {:conversation_event, _, %{"type" => "permission_request"} = ev}, 2_000
      Broker.respond(ev["request_id"], option)
      ev
    end

    test "the event carries everything a client needs, with ACP option kinds", %{conv: conv} do
      task = Task.async(fn -> call(conv, "mcp__x__y", %{"q" => 1}) end)
      ev = answer("allow_once")
      assert %{"output" => "ran"} = Task.await(task)

      assert ev["tool_call_id"] == "call_1"
      assert ev["tool_name"] == "mcp__x__y"
      assert ev["arguments"] == %{"q" => 1}
      assert ev["reason"] == @blocked
      assert ev["risk"] == "high"
      assert ev["turn_id"] == 1
      assert Enum.map(ev["options"], & &1["kind"]) == ["allow_once", "allow_always", "reject_once", "reject_always"]
      assert_receive {:conversation_event, _, %{"type" => "ui_resolved", "request_id" => rid, "outcome" => "answered"}}
      assert rid == ev["request_id"]
    end

    test "allow_once runs this call and asks again for the next", %{conv: conv} do
      t1 = Task.async(fn -> call(conv, "mcp__x__y", %{}) end)
      answer("allow_once")
      assert %{"output" => "ran"} = Task.await(t1)
      t2 = Task.async(fn -> call(conv, "mcp__x__y", %{}, "call_2") end)
      answer("reject_once")
      assert %{"is_error" => true, "output" => "Blocked by extension: " <> _} = Task.await(t2)
    end

    test "allow_always writes the session override, never settings.json", %{conv: conv, app: app} do
      task = Task.async(fn -> call(conv, "mcp__x__y", %{}) end)
      answer("allow_always")
      assert %{"output" => "ran"} = Task.await(task)

      agent = Doc.snapshot("conversation", conv.id, "pi.agent")
      assert agent["settingsOverride"]["permissions"]["allowTools"] == ["mcp__x__y"]
      refute File.exists?(Path.join(app, "settings.json"))

      # Allowed from now on: no prompt, no early block.
      assert %{"output" => "ran"} = call(conv, "mcp__x__y", %{}, "call_2")
      refute_receive {:conversation_event, _, %{"type" => "permission_request"}}, 100
    end

    test "allow_always for a command stores a command(...) entry, and reject_always denies it", %{conv: conv} do
      t1 = Task.async(fn -> call(conv, "bash", %{"command" => "make test"}) end)
      answer("allow_always")
      assert %{"output" => "ran"} = Task.await(t1)
      assert Doc.snapshot("conversation", conv.id, "pi.agent")["settingsOverride"]["permissions"]["allow"] == ["command(make test)"]

      t2 = Task.async(fn -> call(conv, "mcp__x__y", %{}) end)
      answer("reject_always")
      assert %{"is_error" => true} = Task.await(t2)
      assert {:blocked_early, "Tool `mcp__x__y` is blocked by `permissions.denyTools`."} = call(conv, "mcp__x__y", %{}, "call_3")
    end

    test "an ACP style answer is understood", %{conv: conv} do
      task = Task.async(fn -> call(conv, "mcp__x__y", %{}) end)
      answer(%{"outcome" => %{"outcome" => "selected", "optionId" => "allow_once"}})
      assert %{"output" => "ran"} = Task.await(task)
    end

    test "cancelling the turn ends the prompt with a block", %{conv: conv} do
      task = Task.async(fn -> call(conv, "mcp__x__y", %{}) end)
      assert_receive {:conversation_event, _, %{"type" => "permission_request"}}
      Broker.cancel_pending(conv.id)
      assert %{"is_error" => true} = Task.await(task)
      assert_receive {:conversation_event, _, %{"type" => "ui_resolved", "outcome" => "cancelled"}}
    end
  end

  describe "in a machine run" do
    test "the machine keeps answering get_state while the prompt waits, and the tool runs after approval", %{conv: conv} do
      test_pid = self()
      Broker.register_responder(conv.id)
      Phoenix.PubSub.subscribe(SuperPi.PubSub, "conversation:#{conv.id}")

      {:ok, pid} =
        Machine.start_link(
          conversation_id: conv.id,
          extensions: [Permissions],
          llm_responder: Faults.tool_then_text_responder("mcp__x__y", %{}, "done"),
          tool_executor: fn name, _a, _c ->
            send(test_pid, {:executed, name})
            %{"output" => "ok"}
          end
        )

      task = Task.async(fn -> Machine.submit(pid, "go", timeout: 5_000) end)
      assert_receive {:conversation_event, _, %{"type" => "tool_started"}}, 2_000
      assert_receive {:conversation_event, _, %{"type" => "permission_request", "request_id" => rid, "tool_call_id" => "call_1"}}, 2_000

      # The prompt waits in the tool task, not in the machine.
      assert {:executing_tools, _} = :gen_statem.call(pid, :get_state, 1_000)
      refute_received {:executed, _}

      Broker.respond(rid, "allow_once")
      assert {:ok, _} = Task.await(task)
      assert_received {:executed, "mcp__x__y"}
    end

    test "with no client the call is blocked and never executed", %{conv: conv} do
      test_pid = self()

      {:ok, pid} =
        Machine.start_link(
          conversation_id: conv.id,
          extensions: [Permissions],
          llm_responder: Faults.tool_then_text_responder("mcp__x__y", %{}, "done"),
          tool_executor: fn name, _a, _c ->
            send(test_pid, {:executed, name})
            %{"output" => "ok"}
          end
        )

      assert {:ok, _} = Machine.submit(pid, "go", timeout: 5_000)
      refute_received {:executed, _}
    end
  end

  describe "hooks decision ask (D8)" do
    setup %{app: app} do
      hooks_dir = Path.join(app, "ws")
      File.mkdir_p!(Path.join(hooks_dir, ".agents"))
      script = Path.join(hooks_dir, "ask.sh")
      File.write!(script, "#!/bin/sh\ncat >/dev/null\necho '{\"decision\":\"ask\",\"reason\":\"hook wants a human\"}'\n")
      File.chmod!(script, 0o755)

      File.write!(
        Path.join([hooks_dir, ".agents", "hooks.json"]),
        Jason.encode!(%{"hooks" => %{"PreToolUse" => [%{"matcher" => ".*", "hooks" => [%{"type" => "command", "command" => script}]}]}})
      )

      conv = Storage.create_conversation!(agent: %{"executionMode" => "auto", "workspacePaths" => [hooks_dir], "appDataDir" => app})
      {:ok, hconv: conv}
    end

    test "ask without a client still blocks, with the hook's reason", %{hconv: conv} do
      ctx = %{conversation_id: conv.id, tool_call_id: "c1"}
      assert {:block, "hook wants a human"} = Hooks.before_tool("read", %{"path" => "x"}, ctx)
    end

    test "ask with a client prompts, and an approval runs the tool", %{hconv: conv} do
      Broker.register_responder(conv.id)
      Phoenix.PubSub.subscribe(SuperPi.PubSub, "conversation:#{conv.id}")
      ctx = %{conversation_id: conv.id, tool_call_id: "c1", turn_id: 1}

      assert :allow = Hooks.before_tool("read", %{"path" => "x"}, ctx)
      task = Task.async(fn -> Hooks.wrap_tool("read", %{"path" => "x"}, fn _ -> %{"output" => "ran"} end, ctx) end)
      assert_receive {:conversation_event, _, %{"type" => "permission_request", "reason" => "hook wants a human"} = ev}, 2_000
      Broker.respond(ev["request_id"], "allow_once")
      assert %{"output" => "ran"} = Task.await(task)
    end

    test "a refusal blocks the tool", %{hconv: conv} do
      Broker.register_responder(conv.id)
      Phoenix.PubSub.subscribe(SuperPi.PubSub, "conversation:#{conv.id}")
      ctx = %{conversation_id: conv.id, tool_call_id: "c1", turn_id: 1}

      assert :allow = Hooks.before_tool("read", %{"path" => "x"}, ctx)
      task = Task.async(fn -> Hooks.wrap_tool("read", %{"path" => "x"}, fn _ -> %{"output" => "ran"} end, ctx) end)
      assert_receive {:conversation_event, _, %{"type" => "permission_request"} = ev}, 2_000
      Broker.respond(ev["request_id"], "reject_once")
      assert %{"is_error" => true} = Task.await(task)
    end
  end
end
