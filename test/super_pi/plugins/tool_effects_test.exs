defmodule SuperPi.Plugins.ToolEffectsTest do
  @moduledoc """
  Tool effects drive both layers: `Permissions` (is this call allowed?) and `Env.Workspace`
  (is this tool offered at all?). They also cover the safety floor of the four harnesses.
  """
  use SuperPi.DataCase, async: false

  alias SuperPi.Durable.Storage
  alias SuperPi.Env.Workspace
  alias SuperPi.Harness
  alias SuperPi.Plugins.Permissions
  alias SuperPi.Tools

  setup do
    Tools.ensure_catalog_ets!()
    saved = Application.fetch_env(:super_pi, :permissions)
    Application.delete_env(:super_pi, :permissions)

    on_exit(fn ->
      case saved do
        {:ok, v} -> Application.put_env(:super_pi, :permissions, v)
        :error -> Application.delete_env(:super_pi, :permissions)
      end
    end)

    :ok
  end

  defp conv!(agent) do
    app = Path.join(System.tmp_dir!(), "eff_#{System.unique_integer([:positive])}")
    File.mkdir_p!(app)
    on_exit(fn -> File.rm_rf(app) end)

    Storage.create_conversation!(
      agent: Map.merge(%{"workspacePaths" => [File.cwd!()], "appDataDir" => app}, agent)
    )
  end

  defp tool(name, effects), do: %{"name" => name, "effects" => effects}

  defp check(conv, name, args \\ %{}),
    do: Permissions.before_tool(name, args, %{conversation_id: conv.id})

  describe "Tools.effects/2" do
    test "built-in tools have effects" do
      assert Tools.effects("read") == ["read"]
      assert Tools.effects("write") == ["fs_write"]
      assert Tools.effects("bash") == ["exec"]
    end

    test "a plugin tool states its effects on its spec" do
      cfg = %{"tools" => [tool("my_tool", ["net_read"])]}
      assert Tools.effects("my_tool", cfg) == ["net_read"]
    end

    test "an unknown tool and an invalid effect list give nil" do
      assert Tools.effects("nobody") == nil
      assert Tools.effects("t", %{"tools" => [tool("t", ["teleport"])]}) == nil
    end

    test "the artifact, todo, subagent and question tools state effects" do
      for spec <- SuperPi.Artifacts.tool_specs(),
          do: assert(is_list(spec["effects"]), spec["name"])

      assert SuperPi.Plugins.Todo.before_agent_start(%{"tools" => []}, %{})
             |> elem(1)
             |> Map.fetch!("tools")
             |> hd()
             |> Map.fetch!("effects") == ["state_write"]
    end
  end

  describe "Permissions by effect (D4: plugin tools no longer blocked in accept-edits)" do
    test "artifact tools, todo, delegate_subagent and ask_question are allowed in accept-edits" do
      tools =
        SuperPi.Artifacts.tool_specs() ++
          [
            tool("todo", ["state_write"]),
            tool("delegate_subagent", ["state_write"]),
            tool("ask_question", ["read"])
          ]

      conv = conv!(%{"executionMode" => "accept-edits", "tools" => tools})

      for name <- [
            "artifact_get",
            "artifact_list",
            "artifact_put",
            "todo",
            "delegate_subagent",
            "ask_question"
          ] do
        assert :allow = check(conv, name), "#{name} must be allowed in accept-edits"
      end
    end

    test "state changes are blocked in plan mode, pure reads are not" do
      conv =
        conv!(%{
          "executionMode" => "plan",
          "tools" => [tool("todo", ["state_write"]), tool("ask_question", ["read"])]
        })

      assert {:block, _} = check(conv, "todo")
      assert :allow = check(conv, "ask_question")
    end

    test "a tool that states no effects keeps the old behaviour" do
      conv = conv!(%{"executionMode" => "accept-edits", "tools" => [%{"name" => "mystery"}]})

      assert {:block, "Tool `mystery` is not allowed by default in mode `accept-edits`."} =
               check(conv, "mystery")

      assert :allow = check(conv!(%{"executionMode" => "auto"}), "mystery")
    end

    test "a network read is allowed in every mode, a network write only in auto" do
      tools = [tool("peek", ["net_read"]), tool("poke", ["net_write"])]

      for mode <- ["plan", "accept-edits", "auto"] do
        assert :allow = check(conv!(%{"executionMode" => mode, "tools" => tools}), "peek")
      end

      assert {:block, _} =
               check(conv!(%{"executionMode" => "accept-edits", "tools" => tools}), "poke")

      assert {:block, _} = check(conv!(%{"executionMode" => "plan", "tools" => tools}), "poke")
      assert :allow = check(conv!(%{"executionMode" => "auto", "tools" => tools}), "poke")
    end

    test "network_in_plan_mode: false blocks a network read in plan mode" do
      conv =
        conv!(%{
          "executionMode" => "plan",
          "tools" => [tool("peek", ["net_read"])],
          "settingsOverride" => %{"network_in_plan_mode" => false}
        })

      assert {:block, _} = check(conv, "peek")
    end

    test "network: deny blocks every network tool, in every mode" do
      tools = [tool("peek", ["net_read"]), tool("poke", ["net_write"])]

      for mode <- ["plan", "accept-edits", "auto"], name <- ["peek", "poke"] do
        conv =
          conv!(%{
            "executionMode" => mode,
            "tools" => tools,
            "settingsOverride" => %{"network" => "deny"}
          })

        assert {:block, msg} = check(conv, name, %{"url" => "https://example.com"})
        if mode != "plan", do: assert(msg =~ "network")
      end
    end

    test "network: allowlist allows a listed host and its subdomains only" do
      settings = %{"network" => "allowlist", "networkAllowHosts" => ["example.com"]}

      conv =
        conv!(%{
          "executionMode" => "accept-edits",
          "tools" => [tool("peek", ["net_read"])],
          "settingsOverride" => settings
        })

      assert :allow = check(conv, "peek", %{"url" => "https://example.com/a"})
      assert :allow = check(conv, "peek", %{"url" => "https://docs.example.com/a"})
      assert {:block, _} = check(conv, "peek", %{"url" => "https://evil-example.com/a"})
      assert {:block, _} = check(conv, "peek", %{"url" => "https://example.com.evil.net/a"})
      assert {:block, _} = check(conv, "peek", %{})
    end

    test "a promptable block message is the one that earlier releases produced" do
      conv = conv!(%{"executionMode" => "accept-edits", "tools" => [tool("poke", ["net_write"])]})

      assert {:block, "Tool `poke` is not allowed by default in mode `accept-edits`."} =
               check(conv, "poke")

      assert {:block, "Command `make x` is not in `permissions.allow` under mode `accept-edits`."} =
               check(conv, "bash", %{"command" => "make x"})
    end

    test "artifact path arguments stay inside the workspace" do
      conv = conv!(%{"executionMode" => "accept-edits"})

      assert {:block, _} =
               check(conv, "artifact_get", %{"name" => "a", "to_path" => "/etc/passwd"})

      assert {:block, _} = check(conv, "artifact_put", %{"name" => "a", "path" => "/etc/passwd"})
      assert :allow = check(conv, "artifact_put", %{"name" => "a", "content" => "x"})
    end
  end

  describe "maxExecutionMode" do
    test "clamp_mode/1 lowers a mode above the ceiling and keeps the rest" do
      assert %{"executionMode" => "plan"} =
               Permissions.clamp_mode(%{"executionMode" => "auto", "maxExecutionMode" => "plan"})

      assert %{"executionMode" => "plan"} =
               Permissions.clamp_mode(%{"executionMode" => "plan", "maxExecutionMode" => "auto"})

      assert %{"executionMode" => "auto"} = Permissions.clamp_mode(%{"executionMode" => "auto"})
    end

    test "Permissions blocks a write when the stored mode is above the ceiling" do
      conv = conv!(%{"executionMode" => "auto", "maxExecutionMode" => "plan"})
      assert {:block, _} = check(conv, "write", %{"path" => "x", "content" => "y"})
    end
  end

  describe "Workspace :net capability" do
    test "every kind has net, and network false removes it" do
      assert :net in elem(Workspace.build(%{"kind" => "local"}), 1).capabilities
      assert :net in elem(Workspace.build(%{"kind" => "none"}), 1).capabilities

      refute :net in elem(Workspace.build(%{"kind" => "none", "network" => false}), 1).capabilities

      refute :net in elem(Workspace.build(%{"kind" => "local", "network" => false}), 1).capabilities
    end

    test "capabilities follow the effects, and an unknown tool needs them all" do
      assert Workspace.required_capabilities("read") == [:fs]
      assert Workspace.required_capabilities("bash") == [:exec]
      assert Workspace.required_capabilities("artifact_get") == [:artifacts]

      assert Workspace.required_capabilities("x", %{
               "tools" => [tool("x", ["net_read", "state_write"])]
             }) == [:net]

      assert Workspace.required_capabilities("x", %{"tools" => [tool("x", ["read"])]}) == []
      assert Workspace.required_capabilities("who") == [:fs, :exec, :net]
    end

    test "a none workspace offers net tools but no file, shell or unknown tool; network false offers no net tool" do
      tools = [
        %{"name" => "read"},
        %{"name" => "bash"},
        %{"name" => "web_like", "effects" => ["net_read"]},
        %{"name" => "mcp__x__y", "effects" => ["net_write"]},
        %{"name" => "todo", "effects" => ["state_write"]},
        %{"name" => "mystery"}
      ]

      names = fn ws ->
        Workspace.offered_tools(tools, %{"workspace" => ws, "tools" => tools})
        |> Enum.map(& &1["name"])
      end

      none = names.(%{"kind" => "none"})
      assert "web_like" in none and "mcp__x__y" in none and "todo" in none
      refute Enum.any?(["read", "bash", "mystery"], &(&1 in none))

      offline = names.(%{"kind" => "none", "network" => false})
      assert offline -- ["todo", "artifact_put", "artifact_get", "artifact_list"] == []

      local_offline = names.(%{"kind" => "local", "network" => false})
      assert "read" in local_offline and "bash" in local_offline

      refute "web_like" in local_offline or "mcp__x__y" in local_offline or
               "mystery" in local_offline
    end

    test "an MCP tool is refused in a workspace without network" do
      conv = conv!(%{"workspace" => %{"kind" => "none", "network" => false}})
      result = Tools.execute("mcp__x__y", %{}, %{conversation_id: conv.id})
      assert result["is_error"] == true
      assert result["output"] =~ "network"
    end
  end

  describe "the four harnesses" do
    @harnesses [Harness.Code, Harness.Assistant, Harness.Librarian, Harness.Planner]

    test "all of them carry Permissions (D1, D2)" do
      for harness <- @harnesses do
        mods = Enum.map(harness.extensions([]), &if(is_tuple(&1), do: elem(&1, 0), else: &1))
        assert Permissions in mods, "#{inspect(harness)} has no Permissions"
      end
    end

    test "none of them uses the unranked `interactive` mode (D1)" do
      for harness <- @harnesses do
        assert harness.agent_defaults()["executionMode"] in ["plan", "accept-edits", "auto"]
      end
    end

    test "every harness with file tools carries ProtectedPaths" do
      for harness <- [Harness.Code, Harness.Librarian, Harness.Planner] do
        mods = Enum.map(harness.extensions([]), &if(is_tuple(&1), do: elem(&1, 0), else: &1))
        assert SuperPi.Plugins.ProtectedPaths in mods
      end
    end

    test "the assistant offers no file or shell tool, and the same harness without network offers no net tool" do
      tools =
        Harness.Assistant.agent_defaults()["tools"] ++
          [%{"name" => "mcp__a__b", "effects" => ["net_write"]}]

      agent = Harness.Assistant.agent_defaults()

      offered =
        Workspace.offered_tools(tools, Map.put(agent, "tools", tools)) |> Enum.map(& &1["name"])

      refute Enum.any?(["read", "write", "edit", "bash"], &(&1 in offered))
      assert "mcp__a__b" in offered

      offline = Map.put(agent, "workspace", %{"kind" => "none", "network" => false})

      refute "mcp__a__b" in (Workspace.offered_tools(tools, Map.put(offline, "tools", tools))
                             |> Enum.map(& &1["name"]))
    end

    test "the librarian has no bash and its workspace comes from :knowledge_paths" do
      Application.put_env(:super_pi, :knowledge_paths, ["/tmp/vault"])
      on_exit(fn -> Application.delete_env(:super_pi, :knowledge_paths) end)
      defaults = Harness.Librarian.agent_defaults()
      refute "bash" in Enum.map(defaults["tools"], & &1["name"])
      assert defaults["workspacePaths"] == ["/tmp/vault"]
    end

    test "capabilities/0 describes each harness" do
      for harness <- @harnesses do
        caps = Harness.capabilities(harness)
        assert caps["id"] == harness.id()
        assert is_list(caps["plugins"])
        assert caps["maxMode"] in ["plan", "accept-edits", "auto"]
      end

      assert Harness.capabilities(Harness.Assistant)["workspace"] == "none"
      assert Harness.capabilities(Harness.Librarian)["tools"] == %{"except" => ["bash"]}
    end

    test "a harness without capabilities/0 still gets a summary" do
      defmodule Bare do
        @behaviour SuperPi.Harness
        def id, do: "bare"
        def name, do: "Bare"
        def description, do: "bare"
        def extensions(_), do: []
        def agent_defaults(_), do: %{}
      end

      assert %{"id" => "bare"} = Harness.capabilities(Bare)
    end

    test "the defaults ladder prefers opts, then the harness, then config" do
      assert Harness.Code.agent_defaults(effort: "low")["effort"] == "low"
      assert Harness.Code.agent_defaults()["effort"] == "high"
      assert Harness.Code.agent_defaults(workspace_paths: ["/x"])["workspacePaths"] == ["/x"]
      Application.put_env(:super_pi, :workspace_paths, ["/cfg"])
      on_exit(fn -> Application.delete_env(:super_pi, :workspace_paths) end)
      assert Harness.Code.agent_defaults()["workspacePaths"] == ["/cfg"]
    end
  end
end
