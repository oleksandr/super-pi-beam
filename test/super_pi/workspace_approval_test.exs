defmodule SuperPi.WorkspaceApprovalTest do
  use SuperPi.DataCase, async: false

  alias SuperPi.{Tools, Workflow, WorkspaceApproval}
  alias SuperPi.Conversation.Machine
  alias SuperPi.Durable.{Doc, Storage}
  alias SuperPi.Plugins.Permissions
  alias SuperPi.TestSupport.Faults
  alias SuperPi.UI.Broker

  setup do
    base =
      Path.join(System.tmp_dir!(), "workspace_approval_#{System.unique_integer([:positive])}")

    primary = Path.join(base, "primary")
    secondary = Path.join(base, "secondary")
    File.mkdir_p!(primary)
    File.mkdir_p!(secondary)
    File.write!(Path.join(primary, "marker.txt"), "primary")
    File.write!(Path.join(secondary, "marker.txt"), "secondary")
    on_exit(fn -> File.rm_rf(base) end)

    agent = %{
      "harness" => "super-pi-code",
      "workspaceApprovalScope" => "conversation",
      "workspacePaths" => [primary],
      "appDataDir" => base,
      "tools" => [],
      "executionMode" => "accept-edits"
    }

    agent = SuperPi.Plugins.Profiles.configure_agent(agent, %{config: []})
    {:ok, agent} = SuperPi.Plugins.Profiles.select(agent, "build")

    %{agent: agent, primary: primary, secondary: secondary, base: base}
  end

  defp subscribe(id) do
    Broker.register_responder(id)
    Phoenix.PubSub.subscribe(SuperPi.PubSub, "conversation:#{id}")
  end

  defp answer(option) do
    assert_receive {:conversation_event, _, %{"type" => "permission_request"} = ev}, 2000
    assert :ok = Broker.respond(ev["request_id"], option)
    ev
  end

  for mode <- ~w(ask plan build) do
    test "#{mode}: a chat turn can request folder access without lifting mode restrictions",
         ctx do
      {:ok, config} = Workflow.select(ctx.agent, unquote(mode))
      conv = Storage.create_conversation!(agent: config)
      subscribe(conv.id)
      me = self()
      args = %{"path" => ctx.secondary, "reason" => "Review the second repository"}
      responder = Faults.tool_then_text_responder("request_workspace_access", args, "approved")

      {:ok, machine} =
        Machine.start_link(
          conversation_id: conv.id,
          extensions: [Permissions, SuperPi.Plugins.Approvals, SuperPi.Plugins.Profiles],
          tool_executor: fn _, _, _ ->
            flunk("Human approval must bypass the command execution timeout")
          end,
          llm_responder: fn payload, context ->
            send(me, {:payload, payload})
            responder.(payload, context)
          end
        )

      task = Task.async(fn -> Machine.submit(machine, "Trust the second repository") end)
      ev = answer("allow_once")
      assert ev["arguments"]["path"] == Permissions.canonical_path(ctx.secondary)
      assert Enum.map(ev["options"], & &1["option_id"]) == ["allow_once", "reject_once"]
      assert {:ok, _} = Task.await(task)
      assert_receive {:payload, payload}
      assert Enum.any?(payload.tools, &(&1["name"] == "request_workspace_access"))
      agent = Doc.snapshot("conversation", conv.id, "pi.agent")
      assert agent["workspacePaths"] == [ctx.primary, Permissions.canonical_path(ctx.secondary)]
      assert agent["profile"] == unquote(mode)
      assert agent["approvedWorkspacePaths"] == [Permissions.canonical_path(ctx.secondary)]

      read =
        Permissions.evaluate(
          "read",
          %{"path" => Path.join(ctx.secondary, "marker.txt")},
          agent,
          %{}
        )

      assert read == :allow

      edit =
        Permissions.evaluate(
          "write",
          %{"path" => Path.join(ctx.secondary, "marker.txt")},
          agent,
          %{}
        )

      if unquote(mode) == "build",
        do: assert(edit == :allow),
        else: assert(match?({:block, _}, edit))

      assert {:block, _} =
               Permissions.evaluate(
                 "read",
                 %{"path" => Path.join(ctx.base, "outside")},
                 agent,
                 %{}
               )

      assert Permissions.evaluate("bash", %{"command" => "git status"}, agent, %{}) != :allow

      assert {:block, _} =
               Permissions.evaluate(
                 "read",
                 %{"path" => Path.join(ctx.secondary, "marker.txt")},
                 ctx.agent,
                 %{}
               )

      GenServer.stop(machine)
    end
  end

  test "rejection, unavailable UI, cancellation and invalid answers do not add a root", ctx do
    conv = Storage.create_conversation!(agent: ctx.agent)
    args = %{"path" => ctx.secondary, "reason" => "Review"}
    assert %{"is_error" => true} = WorkspaceApproval.request(args, %{conversation_id: conv.id})
    subscribe(conv.id)

    for option <- ["reject_once", "allow_always", "invalid"] do
      task = Task.async(fn -> WorkspaceApproval.request(args, %{conversation_id: conv.id}) end)
      answer(option)
      assert %{"is_error" => true} = Task.await(task)
    end

    task = Task.async(fn -> WorkspaceApproval.request(args, %{conversation_id: conv.id}) end)
    assert_receive {:conversation_event, _, %{"type" => "permission_request"}}, 2000
    Broker.cancel_pending(conv.id)
    assert %{"is_error" => true} = Task.await(task)
    assert Doc.snapshot("conversation", conv.id, "pi.agent")["workspacePaths"] == [ctx.primary]
  end

  test "remote sessions, confined workspaces and policy denials cannot grant workspace access",
       ctx do
    remote =
      Permissions.sanitize_remote_agent(
        Map.put(ctx.agent, "approvedWorkspacePaths", [ctx.secondary])
      )

    refute remote["workspaceApprovalScope"]
    refute remote["approvedWorkspacePaths"]

    for agent <- [
          remote,
          Map.put(ctx.agent, "workspace", %{"kind" => "shared", "root" => ctx.primary}),
          Map.put(ctx.agent, "workspace", %{"kind" => "scratch"}),
          Map.put(ctx.agent, "workspace", %{"kind" => "none"}),
          Map.put(ctx.agent, "settingsOverride", %{
            "permissions" => %{"denyTools" => ["request_workspace_access"]}
          })
        ] do
      conv = Storage.create_conversation!(agent: agent)
      subscribe(conv.id)

      assert %{"is_error" => true} =
               WorkspaceApproval.request(%{"path" => ctx.secondary, "reason" => "Review"}, %{
                 conversation_id: conv.id
               })

      refute_receive {:conversation_event, _, %{"type" => "permission_request"}}, 10
    end
  end

  test "malformed or missing folders are rejected before prompting", ctx do
    conv = Storage.create_conversation!(agent: ctx.agent)
    subscribe(conv.id)

    for path <- [
          nil,
          42,
          ".",
          "~/folder",
          Path.join(ctx.base, "missing"),
          Path.join(ctx.primary, "marker.txt"),
          "/tmp/" <> <<0>>
        ] do
      assert %{"is_error" => true} =
               WorkspaceApproval.request(%{"path" => path, "reason" => "Review"}, %{
                 conversation_id: conv.id
               })
    end

    refute_receive {:conversation_event, _, %{"type" => "permission_request"}}, 10
  end

  test "relative tools and permission checks agree on primary and explicit secondary roots",
       ctx do
    agent = Map.put(ctx.agent, "workspacePaths", [ctx.primary, ctx.secondary])
    conv = Storage.create_conversation!(agent: agent)
    tool_ctx = %{conversation_id: conv.id}
    assert :allow = Permissions.before_tool("read", %{"path" => "marker.txt"}, tool_ctx)
    assert Tools.execute("read", %{"path" => "marker.txt"}, tool_ctx)["output"] == "primary"
    args = %{"path" => "marker.txt", "cd" => ctx.secondary}
    assert :allow = Permissions.before_tool("read", args, tool_ctx)
    assert Tools.execute("read", args, tool_ctx)["output"] == "secondary"
    assert Tools.execute("ls", %{}, tool_ctx)["output"] == "marker.txt"

    assert Tools.execute("bash", %{"command" => "pwd"}, tool_ctx)["output"] =~
             Permissions.canonical_path(ctx.primary)

    for args <- [%{"path" => "marker.txt", "cd" => ctx.base}, %{"path" => "../outside"}] do
      assert {:block, _} = Permissions.before_tool("read", args, tool_ctx)
    end

    File.ln_s!(ctx.base, Path.join(ctx.primary, "escape"))

    assert {:block, _} =
             Permissions.before_tool("read", %{"path" => "escape/../outside"}, tool_ctx)

    assert {:block, _} =
             Permissions.before_tool("list_directory", %{"path" => ctx.base}, tool_ctx)
  end
end
