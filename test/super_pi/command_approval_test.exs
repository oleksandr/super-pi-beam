defmodule SuperPi.CommandApprovalTest do
  use SuperPi.DataCase, async: false

  alias SuperPi.{CommandApproval, CommandRules, GitInspection, Workflow}
  alias SuperPi.Conversation.Machine
  alias SuperPi.Durable.{Doc, Storage}
  alias SuperPi.Plugins.Permissions
  alias SuperPi.TestSupport.Faults
  alias SuperPi.UI.Broker

  @prefixes [["git", "log"], ["git", "status"], ["git", "diff"]]
  @request %{"prefixes" => @prefixes, "reason" => "Review changes against main"}

  setup do
    dir = Path.join(System.tmp_dir!(), "command_approval_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    agent = %{
      "harness" => "super-pi-code",
      "commandRulesScope" => "user",
      "appDataDir" => dir,
      "workspacePaths" => [dir],
      "tools" => SuperPi.Tools.active_llm_tools(),
      "executionMode" => "accept-edits"
    }

    agent =
      SuperPi.Extension.configure_agent(
        [
          SuperPi.Plugins.Approvals,
          {SuperPi.Plugins.Profiles, profiles: SuperPi.Harness.CodeProfiles.all()}
        ],
        agent
      )

    {:ok, agent} = SuperPi.Plugins.Profiles.select(agent, "build")

    %{agent: agent, dir: dir}
  end

  defp subscribe(conv) do
    Broker.register_responder(conv.id)
    Phoenix.PubSub.subscribe(SuperPi.PubSub, "conversation:#{conv.id}")
  end

  defp answer(option) do
    assert_receive {:conversation_event, _, %{"type" => "permission_request"} = ev}, 2000
    assert :ok = Broker.respond(ev["request_id"], option)
    ev
  end

  for mode <- ~w(ask plan build) do
    test "#{mode}: a natural-language turn can request and persist prefixes", %{agent: agent} do
      {:ok, config} = Workflow.select(agent, unquote(mode))
      conv = Storage.create_conversation!(agent: config)
      subscribe(conv)
      me = self()

      responder =
        Faults.tool_then_text_responder("request_command_approval", @request, "approved")

      {:ok, machine} =
        Machine.start_link(
          conversation_id: conv.id,
          extensions: [Permissions, SuperPi.Plugins.Approvals, SuperPi.Plugins.Profiles],
          tool_executor: fn _, _, _ ->
            flunk("Approval must wait in the permission wrapper, outside the command timeout")
          end,
          llm_responder: fn payload, ctx ->
            send(me, {:payload, payload})
            responder.(payload, ctx)
          end
        )

      task =
        Task.async(fn ->
          Machine.submit(machine, "Allow git log, git status and git diff for future sessions")
        end)

      ev = answer("allow_always")
      assert ev["arguments"]["prefixes"] == @prefixes
      assert ev["reason"] =~ "all projects"

      assert Enum.find(ev["options"], &(&1["option_id"] == "allow_always"))["name"] ==
               "Save for future sessions"

      assert {:ok, _} = Task.await(task)
      assert_receive {:payload, payload}
      assert Enum.any?(payload.tools, &(&1["name"] == "request_command_approval"))

      assert Enum.any?(payload.tools, &(&1["name"] == "switch_mode"))

      assert CommandRules.load(agent) == @prefixes

      # A different conversation picks up the saved rule without copying session overrides.
      other = Storage.create_conversation!(agent: agent)

      assert :allow =
               Permissions.before_tool("bash", %{"command" => "git diff --stat"}, %{
                 conversation_id: other.id
               })

      assert config["profile"] ==
               Doc.snapshot("conversation", conv.id, "pi.agent")["profile"]

      GenServer.stop(machine)
    end
  end

  test "conversation-only approval survives resume but does not grant another conversation", %{
    agent: agent
  } do
    conv = Storage.create_conversation!(agent: agent)
    subscribe(conv)
    task = Task.async(fn -> CommandApproval.request(@request, %{conversation_id: conv.id}) end)
    answer("allow_once")
    assert %{"output" => "Approved for this conversation:" <> _} = Task.await(task)
    refute File.exists?(CommandRules.path(agent))

    assert Doc.snapshot("conversation", conv.id, "pi.agent")["settingsOverride"]["permissions"][
             "commandPrefixes"
           ] == @prefixes

    assert :allow =
             Permissions.before_tool("bash", %{"command" => "git log -n 2"}, %{
               conversation_id: conv.id
             })

    other = Storage.create_conversation!(agent: agent)

    assert {:block, _} =
             Permissions.before_tool("bash", %{"command" => "git log -n 2"}, %{
               conversation_id: other.id
             })
  end

  test "rejection, cancellation, and a missing UI never save approval", %{agent: agent} do
    conv = Storage.create_conversation!(agent: agent)
    assert %{"is_error" => true} = CommandApproval.request(@request, %{conversation_id: conv.id})
    subscribe(conv)
    task = Task.async(fn -> CommandApproval.request(@request, %{conversation_id: conv.id}) end)
    answer("reject_once")
    assert %{"is_error" => true} = Task.await(task)
    task = Task.async(fn -> CommandApproval.request(@request, %{conversation_id: conv.id}) end)
    assert_receive {:conversation_event, _, %{"type" => "permission_request"}}
    Broker.cancel_pending(conv.id)
    assert %{"is_error" => true} = Task.await(task)
    refute File.exists?(CommandRules.path(agent))
    refute Doc.snapshot("conversation", conv.id, "pi.agent")["settingsOverride"]
  end

  test "remote sessions cannot create or inherit user rules", %{agent: agent} do
    :ok = CommandRules.save(agent, @prefixes)
    remote = Permissions.sanitize_remote_agent(agent)
    refute remote["commandRulesScope"]
    refute "commandRulesScope" in Map.keys(remote)
    conv = Storage.create_conversation!(agent: Map.put(remote, "appDataDir", agent["appDataDir"]))

    assert {:block, _} =
             Permissions.before_tool("bash", %{"command" => "git diff"}, %{
               conversation_id: conv.id
             })

    subscribe(conv)

    task =
      Task.async(fn ->
        CommandApproval.request(%{@request | "prefixes" => [["make", "test"]]}, %{
          conversation_id: conv.id
        })
      end)

    ev = answer("allow_always")
    refute Enum.any?(ev["options"], &(&1["option_id"] == "allow_always"))
    assert %{"is_error" => true} = Task.await(task)
    assert CommandRules.load(agent) == @prefixes
  end

  test "saved approvals do not override Ask, Plan shell restrictions or explicit denials", %{
    agent: agent
  } do
    :ok = CommandRules.save(agent, @prefixes)
    settings = Permissions.load_effective_settings(agent)
    {:ok, ask} = Workflow.select(agent, "ask")
    {:ok, plan} = Workflow.select(agent, "plan")

    assert :allow =
             Permissions.evaluate("git_inspect", %{"operation" => "diff"}, ask, settings)

    assert {:block, _} = Permissions.evaluate("bash", %{"command" => "git diff"}, plan, settings)

    assert :allow =
             Permissions.evaluate(
               "git_inspect",
               %{"operation" => "diff", "args" => ["main...HEAD", "--stat"]},
               plan,
               settings
             )

    denied = put_in(settings, ["permissions", "deny"], ["command(git diff)"])

    assert {:block, _} =
             Permissions.evaluate("git_inspect", %{"operation" => "diff"}, plan, denied)

    assert {:block, _} =
             Permissions.evaluate(
               "git_inspect",
               %{"operation" => "diff", "cd" => "/"},
               plan,
               settings
             )

    assert {:block, _} =
             Permissions.evaluate(
               "git_inspect",
               %{"operation" => "diff", "args" => ["--output=oops"]},
               plan,
               settings
             )
  end

  test "prefix rules cannot approve unlisted commands, expansions or redirections" do
    assert CommandRules.matches?("git log --oneline -n 5", @prefixes)
    assert CommandRules.matches?("git diff 'main...HEAD'", @prefixes)
    refute CommandRules.matches?("git logfile", @prefixes)

    for command <- [
          "git log; touch x",
          "git log && touch x",
          "git log | sh",
          "git log > x",
          "git log $(touch x)",
          "git log `touch x`",
          "git log & touch x",
          "git log\ntouch x",
          "git log $ARGS",
          "git log *",
          "X=1 git log"
        ] do
      refute CommandRules.matches?(command, @prefixes), command
    end

    for prefixes <- [
          [],
          [["git diff"]],
          [["git", "diff;touch"]],
          [["git", "$(id)"]],
          [["X=1"]],
          "git"
        ] do
      assert {:error, _} = CommandRules.validate(prefixes)
    end
  end

  test "saved, conversation and legacy rules compose without another approval dialog", %{
    agent: agent
  } do
    :ok = CommandRules.save(agent, [["git", "status"]])

    agent =
      Map.put(agent, "settingsOverride", %{
        "permissions" => %{
          "commandPrefixes" => [["git", "fetch"]],
          "allow" => ["command(git log)"]
        }
      })

    conv = Storage.create_conversation!(agent: agent)
    subscribe(conv)
    ctx = %{conversation_id: conv.id}

    command =
      "git status --short --branch && git fetch origin && git log --oneline --max-count=5 HEAD && git log --oneline HEAD..origin/main"

    args = %{"command" => command}
    assert :allow = Permissions.before_tool("bash", args, ctx)
    me = self()

    next = fn actual ->
      send(me, {:executed, actual})
      %{"output" => "done"}
    end

    assert %{"output" => "done"} = Permissions.wrap_tool("bash", args, next, ctx)
    assert_receive {:executed, ^args}
    refute_receive {:conversation_event, _, %{"type" => "permission_request"}}, 10

    # A new, unapproved command must still show a dialog; rejection executes nothing.
    task =
      Task.async(fn ->
        Permissions.wrap_tool("bash", %{"command" => command <> " && git push"}, next, ctx)
      end)

    answer("reject_once")
    assert %{"is_error" => true} = Task.await(task)
    refute_receive {:executed, _}, 10
  end

  test "saving merges concurrent approvals and preserves malformed files", %{agent: agent} do
    tasks = for prefix <- @prefixes, do: Task.async(fn -> CommandRules.save(agent, [prefix]) end)
    assert Enum.all?(Task.await_many(tasks), &(&1 == :ok))
    assert Enum.sort(CommandRules.load(agent)) == Enum.sort(@prefixes)
    file = CommandRules.path(agent)
    File.write!(file, "broken JSON")
    assert {:error, _} = CommandRules.save(agent, [["make", "test"]])
    assert File.read!(file) == "broken JSON"
    assert CommandRules.load(agent) == []
  end

  test "Git inspection rejects options that can write or execute helpers" do
    for {operation, args} <- [
          {"diff", ["--output=x"]},
          {"log", ["--output", "x"]},
          {"diff", ["--ext-diff"]},
          {"log", ["--textconv"]},
          {"log", ["--show-signature"]},
          {"diff", ["--no-index", "/etc/passwd", "x"]},
          {"status", ["--", "../outside"]},
          {"push", []}
        ] do
      assert {:error, _} = GitInspection.argv(%{"operation" => operation, "args" => args})
    end
  end

  test "Git inspection reads real changes without running configured helpers", %{dir: dir} do
    git = fn args ->
      {output, status} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
      assert status == 0, output
      output
    end

    git.(["init", "-q"])
    File.write!(Path.join(dir, "file.txt"), "before\n")
    git.(["add", "file.txt"])

    git.([
      "-c",
      "user.name=Test",
      "-c",
      "user.email=test@example.invalid",
      "commit",
      "-qm",
      "initial"
    ])

    File.write!(Path.join(dir, "file.txt"), "after\n")
    marker = Path.join(dir, "helper-ran")
    git.(["config", "diff.external", "touch #{marker}"])
    git.(["config", "core.fsmonitor", "touch #{marker}"])

    for operation <- ~w(status log diff) do
      result = GitInspection.execute(%{"operation" => operation}, SuperPi.Env.Local, dir)
      refute result["is_error"], result["output"]
      if operation == "diff", do: assert(result["output"] =~ "+after")
    end

    refute File.exists?(marker)
    assert File.read!(Path.join(dir, "file.txt")) == "after\n"
  end
end
