defmodule SuperPi.ProfilesTest do
  use SuperPi.DataCase, async: false

  alias SuperPi.{Discovery, Extension}
  alias SuperPi.Conversation.Machine
  alias SuperPi.Durable.{Doc, Storage}
  alias SuperPi.Plugins.{Permissions, Profiles, PromptCustomizer}
  alias SuperPi.UI.Broker
  alias SuperPi.TestSupport.Faults

  defmodule CustomHarness do
    use SuperPi.Harness,
      id: "custom-profiles",
      name: "Custom",
      description: "Test composition",
      mode: "accept-edits",
      max_mode: "accept-edits",
      tools: {:only, ["read", "write"]},
      plugins: [
        SuperPi.Plugins.Permissions,
        {SuperPi.Plugins.Profiles, profiles: SuperPi.Harness.CodeProfiles.all(), discover: false},
        SuperPi.Plugins.PromptCustomizer
      ]
  end

  defmodule ExtraTools do
    use SuperPi.Extension

    def before_agent_start(agent, _ctx) do
      {:ok,
       Map.update!(agent, "tools", &(&1 ++ [%{"name" => "extra_read", "effects" => ["read"]}]))}
    end
  end

  defmodule NonCodingHarness do
    use SuperPi.Harness,
      id: "non-coding-profiles",
      name: "Guide",
      description: "A domain-neutral Profiles composition",
      mode: "plan",
      max_mode: "plan",
      workspace: %{"kind" => "none"},
      tools: {:only, []},
      plugins: [
        SuperPi.Plugins.Permissions,
        {SuperPi.Plugins.Profiles,
         profiles: [
           %{id: "quick", prompt: "Answer briefly.", effort: "low"},
           %{id: "explain", prompt: "Explain step by step.", effort: "high", tools: {:only, []}}
         ],
         default: :quick,
         discover: false}
      ]
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "profiles_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir, agent: CustomHarness.agent_defaults(workspace_paths: [dir])}
  end

  defp snapshot(conv), do: Doc.snapshot("conversation", conv.id, "pi.agent")

  test "Profiles requires explicit valid definitions" do
    assert_raise KeyError, fn -> Profiles.configure_agent(%{}, %{config: []}) end

    for definitions <- [[:ask], [%{id: "invalid", execution_mode: "unsafe"}], :all] do
      assert_raise ArgumentError, fn ->
        Profiles.configure_agent(%{}, %{config: [profiles: definitions]})
      end
    end
  end

  test "noncoding profiles have only their own prompts and the declared harness loadout" do
    agent = NonCodingHarness.agent_defaults()
    assert agent["profile"] == "quick"
    assert Enum.map(agent["tools"], & &1["name"]) == ["switch_mode"]
    assert Enum.map(agent["profiles"], & &1["id"]) == ["quick", "explain"]
    {:ok, selected} = SuperPi.SessionModes.select(agent, "explain")
    {:ok, request} = Profiles.prepare_request(selected, %{})
    assert request["effort"] == "high"
    assert List.last(request["systemSections"])["content"] == "Explain step by step."
    assert NonCodingHarness.capabilities()["sessionModes"]["currentModeId"] == "quick"
  end

  test "Profiles owns commands in either order and honors disabled slash commands", %{
    agent: agent
  } do
    for extensions <- [
          [SuperPi.Plugins.SlashCommands, Profiles],
          [Profiles, SuperPi.Plugins.SlashCommands]
        ] do
      conv = Storage.create_conversation!(agent: agent)
      ctx = %{conversation_id: conv.id}
      assert :handled = Extension.run_on_input(extensions, "/mode build", ctx)
      assert snapshot(conv)["profile"] == "build"
      assert :handled = Extension.run_on_input(extensions, "/workflow ask", ctx)
      assert snapshot(conv)["profile"] == "ask"

      assert {:continue, "Review this", []} =
               Extension.run_on_input(extensions, "/plan Review this", ctx)

      assert snapshot(conv)["profile"] == "plan"

      Storage.configure_agent!(conv.id, %{"disableSlashCommands" => true})

      assert {:continue, "/mode build", []} =
               Extension.run_on_input(extensions, "/mode build", ctx)

      assert snapshot(conv)["profile"] == "plan"
    end
  end

  test "existing profile snapshots migrate to the generic policy without losing approvals", %{
    agent: agent
  } do
    previous =
      agent
      |> Map.drop(~w(toolPolicy sessionMode modeProviders toolProviders pluginToolNames))
      |> Map.put("settingsOverride", %{
        "permissions" => %{"commandPrefixes" => [["git", "status"]]}
      })
      |> Map.put("approvedWorkspacePaths", ["/tmp/trusted"])

    migrated = Extension.configure_agent(CustomHarness.extensions(), previous)
    assert migrated["profilePolicy"] == previous["profilePolicy"]
    assert migrated["settingsOverride"] == previous["settingsOverride"]
    assert migrated["approvedWorkspacePaths"] == previous["approvedWorkspacePaths"]
    assert migrated["toolPolicy"]["executionMode"] == "plan"
    assert SuperPi.SessionModes.list(migrated)["currentModeId"] == "ask"
  end

  defp switch(conv, mode, plan \\ nil),
    do:
      Profiles.execute_tool(
        "switch_mode",
        %{"mode" => mode, "plan" => plan},
        %{conversation_id: conv.id}
      )

  test "any harness can compose presets while its tools and permission ceiling remain the boundary",
       %{agent: agent} do
    assert agent["profile"] == "ask"
    {:ok, request} = Profiles.prepare_request(agent, %{})
    assert Enum.map(request["tools"], & &1["name"]) == ["read", "switch_mode"]
    {:ok, build} = Profiles.select(agent, "build")
    {:ok, request} = Profiles.prepare_request(build, %{})
    assert Enum.map(request["tools"], & &1["name"]) == ["read", "write", "switch_mode"]
    refute Enum.any?(request["tools"], &(&1["name"] == "bash"))

    planner =
      SuperPi.Harness.Planner.agent_defaults()
      |> Profiles.configure_agent(%{config: [profiles: SuperPi.Harness.CodeProfiles.all()]})

    assert {:error, _} = Profiles.select(planner, "build")
    assert {:error, _} = Profiles.select(planner, "auto")
    assert Enum.all?(Profiles.available(planner), &(&1["execution_mode"] == "plan"))
  end

  test "custom filters block forced calls and overrides are request-only", %{agent: agent} do
    config = [
      profiles: [
        SuperPi.Harness.CodeProfiles.get(:build),
        %{
          id: "review",
          tools: {:except, ["write"]},
          model: "gpt-6-astra",
          effort: "high",
          prompt: "REVIEW_SENTINEL"
        }
      ],
      default: :review,
      discover: false
    ]

    agent =
      agent
      |> Map.drop(["profilesConfig", "profilePolicy", "profile"])
      |> Map.put("model", "base-model")
      |> Profiles.configure_agent(%{config: config})

    conv = Storage.create_conversation!(agent: agent)
    assert {:block, _} = Permissions.before_tool("write", %{}, %{conversation_id: conv.id})

    {stored, request} =
      Extension.run_agent_start([Profiles, PromptCustomizer], agent, %{conversation_id: conv.id})

    assert stored == agent
    assert request["model"] == "gpt-6-astra"
    assert request["effort"] == "high"
    assert inspect(request["systemSections"]) =~ "REVIEW_SENTINEL"

    assert {:ok, payload} =
             Profiles.before_provider_request(%{model: "router-model", tools: agent["tools"]}, %{
               conversation_id: conv.id
             })

    assert payload.model == "gpt-6-astra"
    assert payload.effort == "high"
    body = SuperPi.AI.Providers.OpenAI.build_responses_body(payload)
    assert body["reasoning"] == %{"effort" => "high"}
    {:ok, build} = Profiles.select(stored, "build")
    {:ok, restored} = Profiles.prepare_request(build, %{})
    assert restored["model"] == "base-model"
    assert Enum.any?(restored["tools"], &(&1["name"] == "write"))
  end

  test "extra tool providers assemble the loadout before request filtering", %{agent: agent} do
    {stored, request} =
      Extension.run_agent_start([Profiles, PromptCustomizer, ExtraTools], agent, %{})

    assert Enum.any?(stored["tools"], &(&1["name"] == "extra_read"))
    assert Enum.any?(request["tools"], &(&1["name"] == "extra_read"))
    assert Enum.any?(stored["tools"], &(&1["name"] == "write"))
    refute Enum.any?(request["tools"], &(&1["name"] == "write"))
  end

  for answer <- ["allow_once", "reject_once", "allow_always"] do
    test "raising permissions: #{answer}", %{agent: agent} do
      {:ok, agent} = Profiles.select(agent, "plan")
      conv = Storage.create_conversation!(agent: agent)
      Broker.register_responder(conv.id)
      Phoenix.PubSub.subscribe(SuperPi.PubSub, "conversation:#{conv.id}")
      task = Task.async(fn -> switch(conv, "build", "1. Implement\n2. Verify") end)
      assert_receive {:conversation_event, _, %{"type" => "permission_request"} = event}, 2000
      assert event["reason"] =~ "1. Implement\n2. Verify"
      assert Enum.map(event["options"], & &1["option_id"]) == ["allow_once", "reject_once"]
      assert snapshot(conv)["profile"] == "plan"
      :ok = Broker.respond(event["request_id"], unquote(answer))
      result = Task.await(task)

      if unquote(answer) == "allow_once" do
        refute result["is_error"]
        assert snapshot(conv)["profile"] == "build"
        assert snapshot(conv)["executionMode"] == "accept-edits"
      else
        assert result["is_error"]
        assert snapshot(conv)["profile"] == "plan"
      end
    end
  end

  test "no UI, cancellation and a stale policy never raise permissions; lowering needs no UI", %{
    agent: agent
  } do
    conv = Storage.create_conversation!(agent: agent)
    assert switch(conv, "build")["is_error"]
    assert snapshot(conv)["profile"] == "ask"
    Broker.register_responder(conv.id)
    Phoenix.PubSub.subscribe(SuperPi.PubSub, "conversation:#{conv.id}")
    task = Task.async(fn -> switch(conv, "build") end)
    assert_receive {:conversation_event, _, %{"type" => "permission_request"}}, 2000
    Broker.cancel_pending(conv.id)
    assert Task.await(task)["is_error"]
    assert snapshot(conv)["profile"] == "ask"
    task = Task.async(fn -> switch(conv, "build") end)
    assert_receive {:conversation_event, _, %{"type" => "permission_request"} = event}, 2000
    Storage.configure_agent!(conv.id, %{"maxExecutionMode" => "plan"})
    Broker.respond(event["request_id"], "allow_once")
    assert Task.await(task)["is_error"]
    {:ok, build} = Profiles.select(agent, "build")
    other = Storage.create_conversation!(agent: build)
    refute switch(other, "ask")["is_error"]
    assert snapshot(other)["profile"] == "ask"
  end

  test "model-requested switch uses the next profile in the same conversation", %{agent: agent} do
    conv = Storage.create_conversation!(agent: agent)
    Broker.register_responder(conv.id)
    Phoenix.PubSub.subscribe(SuperPi.PubSub, "conversation:#{conv.id}")
    me = self()

    responder =
      Faults.tool_then_text_responder(
        "switch_mode",
        %{"mode" => "build", "plan" => "Implement"},
        "done"
      )

    {:ok, pid} =
      Machine.start_link(
        conversation_id: conv.id,
        extensions: CustomHarness.extensions(),
        llm_responder: fn payload, ctx ->
          send(me, {:payload, payload})
          responder.(payload, ctx)
        end
      )

    task = Task.async(fn -> Machine.submit(pid, "Implement this") end)
    assert_receive {:conversation_event, _, %{"type" => "permission_request"} = event}, 2000
    Broker.respond(event["request_id"], "allow_once")
    assert {:ok, _} = Task.await(task)
    assert_receive {:payload, ask}
    assert_receive {:payload, build}
    refute Enum.any?(ask.tools, &(&1["name"] == "write"))
    assert Enum.any?(build.tools, &(&1["name"] == "write"))
    assert inspect(build.messages) =~ "Implement this"
    GenServer.stop(pid)
  end

  test "Markdown discovery, precedence, aliases and subagent exclusion", %{dir: dir} do
    File.mkdir_p!(Path.join(dir, ".git"))

    for folder <- [".agents/agents", ".opencode/agents", ".claude/agents"],
        do: File.mkdir_p!(Path.join(dir, folder))

    File.write!(
      Path.join(dir, ".agents/agents/reviewer.md"),
      "---\ndescription: Review changes\nmode: primary\ntools: [Read, Grep, Glob]\nmodel: gpt-6-astra\n---\nReview correctness and cite findings.\n"
    )

    File.write!(
      Path.join(dir, ".opencode/agents/reviewer.md"),
      "---\ndescription: lower priority\n---\nIgnored\n"
    )

    File.write!(
      Path.join(dir, ".opencode/agents/architect.md"),
      "---\nmode: all\ntools:\n  write: false\n  edit: false\n---\nCompare designs.\n"
    )

    File.write!(
      Path.join(dir, ".claude/agents/worker.md"),
      "---\nmode: subagent\n---\nPhase two.\n"
    )

    File.write!(
      Path.join(dir, ".claude/agents/search.md"),
      "---\ntools:\n  - Read\n  - Grep\n---\nSearch.\n"
    )

    File.write!(Path.join(dir, "outside.md"), "---\ndescription: outside\n---\nOutside\n")
    File.ln_s!(Path.join(dir, "outside.md"), Path.join(dir, ".agents/agents/escape.md"))
    profiles = Discovery.discover_agents([dir], global_config_dir: dir)
    assert Enum.map(profiles, & &1["id"]) == ["reviewer", "architect", "search"]
    assert hd(profiles)["tools"] == %{"only" => ["read", "grep", "find"]}
    assert hd(profiles)["description"] == "Review changes"
    assert Enum.at(profiles, 1)["tools"] == %{"except" => ["write", "edit"]}
    assert Enum.at(profiles, 2)["tools"] == %{"only" => ["read", "grep"]}
    agent = SuperPi.Harness.Code.agent_defaults(workspace_paths: [dir])
    {:ok, selected} = Profiles.select(agent, "reviewer")
    assert selected["profilePolicy"]["prompt"] =~ "cite findings"

    File.write!(
      Path.join(dir, ".agents/agents/reviewer.md"),
      "---\nexecution_mode: auto\n---\nChanged.\n"
    )

    refreshed = Profiles.configure_agent(selected, %{config: []})
    assert refreshed["profilePolicy"] == selected["profilePolicy"]
    assert refreshed["executionMode"] == "plan"
  end

  test "legacy workflow migration preserves approvals and never changes custom safety plugins", %{
    agent: agent
  } do
    legacy =
      agent
      |> Map.drop(["profile", "profilePolicy", "profilesConfig"])
      |> Map.merge(%{"workflowMode" => "plan", "settingsOverride" => %{"sentinel" => true}})

    migrated =
      Profiles.configure_agent(legacy, %{config: [profiles: SuperPi.Harness.CodeProfiles.all()]})

    assert migrated["profile"] == "plan"
    assert migrated["workflowMode"] == nil
    assert migrated["settingsOverride"] == %{"sentinel" => true}

    assert Extension.active(
             [Permissions, Profiles, SuperPi.Plugins.Hooks, SuperPi.Plugins.ProtectedPaths],
             migrated
           ) == [Permissions, Profiles, SuperPi.Plugins.ProtectedPaths]
  end
end
