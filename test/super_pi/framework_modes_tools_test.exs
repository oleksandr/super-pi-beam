defmodule SuperPi.FrameworkModesToolsTest do
  use SuperPi.DataCase, async: false
  alias SuperPi.{Extension, SessionModes, PluginTools, Tools}
  alias SuperPi.Plugins.Permissions
  alias SuperPi.Durable.Storage

  defmodule ResearchTools do
    use SuperPi.Extension
    def id, do: "research-tools"
    def lifecycle_effects, do: []

    def tools(_),
      do: [
        %{
          "name" => "request_research_policy",
          "effects" => ["state_write"],
          "administrative" => true,
          "parameters" => %{}
        },
        %{"name" => "lookup_fact", "effects" => ["read"], "parameters" => %{}},
        %{"name" => "save_fact", "effects" => ["state_write"], "parameters" => %{}},
        %{
          "name" => "read_archive",
          "effects" => ["read"],
          "capabilities" => ["fs"],
          "parameters" => %{}
        }
      ]

    def tool_policy("lookup_fact", %{"query" => "forbidden"}, _),
      do: {:error, "Provider rejected the query"}

    def tool_policy(_, _, _), do: {:ok, %{}}
    def execute_tool(name, _, _), do: %{"output" => "handled by owner: #{name}"}
  end

  defmodule ResearchModes do
    use SuperPi.Extension
    def id, do: "research-modes"
    def lifecycle_effects, do: []

    def configure_agent(agent, _),
      do: agent |> Map.put_new("sessionMode", "quick") |> Map.put_new("executionMode", "plan")

    def session_modes(agent, _),
      do: %{
        "currentModeId" => agent["sessionMode"],
        "availableModes" => [
          %{"id" => "quick", "name" => "Quick answer", "executionMode" => "plan"},
          %{"id" => "research", "name" => "Research", "executionMode" => "accept-edits"}
        ]
      }

    def select_mode(agent, "research", _),
      do:
        {:ok,
         Map.merge(agent, %{
           "sessionMode" => "research",
           "executionMode" => "accept-edits",
           "effort" => "high"
         })}

    def select_mode(agent, "quick", _),
      do: {:ok, Map.merge(agent, %{"sessionMode" => "quick", "executionMode" => "plan"})}

    def select_mode(_, _, _), do: {:error, "Unknown research mode"}
    def mode_state(agent, _), do: Map.take(agent, ["sessionMode", "executionMode", "effort"])
  end

  defmodule ResearchHarness do
    use SuperPi.Harness,
      id: "research-contract",
      name: "Research",
      description: "Non-coding contract example",
      mode: "plan",
      max_mode: "accept-edits",
      workspace: %{"kind" => "none"},
      tools: {:only, []},
      plugins: [
        SuperPi.Plugins.Permissions,
        SuperPi.FrameworkModesToolsTest.ResearchTools,
        SuperPi.FrameworkModesToolsTest.ResearchModes
      ]
  end

  test "a mode provider works through ACP without importing Profiles" do
    session = SuperPi.ACP.Session.create("contract-test", File.cwd!(), ResearchHarness)
    id = session.conversation_id
    assert SuperPi.ACP.Session.modes(id)["currentModeId"] == "quick"
    assert :ok = SuperPi.ACP.Session.set_mode(id, "research")
    assert [%{"currentValue" => "research"}] = SuperPi.ACP.Session.config_options(id)
    assert ResearchHarness.capabilities()["sessionModes"]["currentModeId"] == "quick"
    agent = ResearchHarness.agent_defaults()

    assert {:error, _} =
             SessionModes.select(Map.put(agent, "maxExecutionMode", "plan"), "research")

    {:ok, selected} = SessionModes.select(agent, "research")
    restored = SessionModes.restore(ResearchHarness.agent_defaults(), selected)
    assert SessionModes.list(restored)["currentModeId"] == "research"
    assert restored["effort"] == "high"

    refute Enum.any?(
             agent["tools"],
             &(&1["name"] in ~w(read bash request_command_approval switch_mode))
           )
  end

  test "workspace requirements come from trusted declarations" do
    agent = ResearchHarness.agent_defaults()
    {:ok, ws} = SuperPi.Env.Workspace.build(agent["workspace"])
    refute SuperPi.Env.Workspace.supports?(ws, "read_archive", agent)

    offered = SuperPi.Env.Workspace.offered_tools(agent["tools"], agent)
    refute Enum.any?(offered, &(&1["name"] == "read_archive"))
    assert Enum.any?(offered, &(&1["name"] == "lookup_fact"))
  end

  test "removed providers leave no stale tool declarations or executable handlers" do
    agent = PluginTools.declare([], ResearchHarness.agent_defaults())
    assert agent["tools"] == []
    refute PluginTools.administrative?("request_research_policy", agent)
    assert PluginTools.execute("lookup_fact", %{}, %{agent: agent}) == :unhandled
  end

  test "declared administrative tools work in plan without core name branches" do
    agent = ResearchHarness.agent_defaults()
    conv = Storage.create_conversation!(agent: agent)
    ctx = %{conversation_id: conv.id}
    assert :allow = Permissions.before_tool("request_research_policy", %{}, ctx)

    result =
      Extension.run_wrap_tool(
        ResearchHarness.extensions(),
        "request_research_policy",
        %{},
        fn _ -> flunk("interactive tools must bypass the sandbox execution timeout") end,
        ctx
      )

    assert result["output"] =~ "handled by owner"

    assert {:block, _} =
             Permissions.evaluate("request_research_policy", %{}, agent, %{
               "permissions" => %{"denyTools" => ["request_research_policy"]}
             })

    assert {:block, _} =
             Permissions.evaluate("lookup_fact", %{"query" => "forbidden"}, agent, %{})

    assert Tools.execute("lookup_fact", %{}, ctx)["output"] == "handled by owner: lookup_fact"
  end

  test "client-supplied administrative metadata does not grant authority" do
    forged = %{
      "executionMode" => "plan",
      "tools" => [%{"name" => "forged", "administrative" => true, "effects" => ["state_write"]}]
    }

    refute PluginTools.administrative?("forged", forged)
    assert {:block, _} = Permissions.evaluate("forged", %{}, forged, %{})

    sanitized =
      Permissions.sanitize_remote_agent(
        Map.merge(forged, %{
          "toolProviders" => [Atom.to_string(ResearchTools)],
          "modeProviders" => [Atom.to_string(ResearchModes)],
          "toolPolicy" => %{}
        })
      )

    refute Map.has_key?(sanitized, "toolProviders")
    refute Map.has_key?(sanitized, "modeProviders")
    refute Map.has_key?(sanitized, "toolPolicy")
  end

  test "hidden custom tools remain blocked in build and for forced calls" do
    agent =
      ResearchHarness.agent_defaults()
      |> Map.merge(%{
        "executionMode" => "accept-edits",
        "toolPolicy" => %{
          "executionMode" => "accept-edits",
          "restrictToLoadout" => true,
          "tools" => %{"only" => ["lookup_fact"]}
        }
      })

    assert {:block, _} = Permissions.evaluate("save_fact", %{}, agent, %{})
    assert {:block, _} = Permissions.evaluate("write", %{"path" => "file"}, agent, %{})

    assert Enum.map(Permissions.offered_tools(agent["tools"], agent), & &1["name"]) == [
             "request_research_policy",
             "lookup_fact"
           ]

    assert {:block, _} =
             Permissions.evaluate(
               "save_fact",
               %{},
               Map.put(agent, "dangerouslySkipPermissions", true),
               %{}
             )
  end
end
