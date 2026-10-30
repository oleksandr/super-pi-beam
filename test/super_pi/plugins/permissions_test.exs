defmodule SuperPi.Plugins.PermissionsTest do
  use SuperPi.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias SuperPi.Durable.{Doc, Storage}
  alias SuperPi.Gateway.Router
  alias SuperPi.Harness
  alias SuperPi.Plugins.Permissions

  setup do
    SuperPi.Tools.ensure_catalog_ets!()
    saved = Application.fetch_env(:super_pi, :permissions)

    on_exit(fn ->
      case saved do
        {:ok, v} -> Application.put_env(:super_pi, :permissions, v)
        :error -> Application.delete_env(:super_pi, :permissions)
      end
    end)

    Application.delete_env(:super_pi, :permissions)
    :ok
  end

  defp conv!(extra \\ %{}) do
    app = Path.join(System.tmp_dir!(), "perm_#{System.unique_integer([:positive])}")
    File.mkdir_p!(app)
    on_exit(fn -> File.rm_rf(app) end)
    Storage.create_conversation!(agent: Map.merge(%{"workspacePaths" => [File.cwd!()], "appDataDir" => app}, extra))
  end

  defp check(conv, tool, args), do: Permissions.before_tool(tool, args, %{conversation_id: conv.id})

  describe "remote_mode/1" do
    test "defaults to accept-edits" do
      assert Permissions.remote_mode(nil) == "accept-edits"
      assert Permissions.remote_mode("bogus") == "accept-edits"
    end

    test "a request can tighten the mode" do
      assert Permissions.remote_mode("plan") == "plan"
    end

    test "a request cannot raise the mode above the ceiling" do
      assert Permissions.remote_mode("auto") == "accept-edits"
    end

    test "config can raise the ceiling" do
      Application.put_env(:super_pi, :permissions, remote_max_mode: "auto")
      assert Permissions.remote_mode("auto") == "auto"
      assert Permissions.remote_mode(nil) == "accept-edits"
    end

    test "config can lower the default and the ceiling" do
      Application.put_env(:super_pi, :permissions, remote_default_mode: "plan")
      assert Permissions.remote_mode("auto") == "plan"
    end
  end

  describe "sanitize_remote_agent/1" do
    test "removes keys that lift the policy and limits the mode" do
      agent = %{
        "dangerouslySkipPermissions" => true,
        "settingsOverride" => %{"allowNonWorkspaceAccess" => true},
        "workspacePaths" => ["/"],
        "executionMode" => "auto",
        "model" => "gemini-3-flash-preview"
      }

      assert Permissions.sanitize_remote_agent(agent) ==
               %{"executionMode" => "accept-edits", "model" => "gemini-3-flash-preview"}
    end
  end

  describe "workspace boundary is on by default" do
    test "blocks a path outside the workspace" do
      assert {:block, _} = check(conv!(), "read", %{"path" => "/etc/hosts"})
    end

    test "allows a path inside the workspace" do
      assert :allow = check(conv!(), "read", %{"path" => Path.join(File.cwd!(), "mix.exs")})
    end

    test "blocks read, write and edit without a path" do
      for tool <- ["read", "write", "edit"], do: assert({:block, _} = check(conv!(), tool, %{}))
    end

    test "listing tools without a path use the workspace" do
      for tool <- ["ls", "grep", "find"], do: assert(:allow = check(conv!(), tool, %{}))
    end

    test "covers read_file and write_file" do
      assert {:block, _} = check(conv!(), "write_file", %{"path" => "/etc/hosts"})
    end

    test "settings can lift the confinement" do
      conv = conv!(%{"settingsOverride" => %{"allowNonWorkspaceAccess" => true}})
      assert :allow = check(conv, "read", %{"path" => "/etc/hosts"})
    end

    test "app config can lift the confinement" do
      Application.put_env(:super_pi, :permissions, allowNonWorkspaceAccess: true)
      assert :allow = check(conv!(), "read", %{"path" => "/etc/hosts"})
    end
  end

  describe "permissions.deny" do
    setup do
      %{conv: conv!(%{"settingsOverride" => %{"permissions" => %{"deny" => ["command(curl)"]}}})}
    end

    test "blocks a denied command in auto mode", %{conv: conv} do
      assert {:block, _} = check(conv, "bash", %{"command" => "curl http://example.com"})
    end

    test "blocks a denied command after a shell operator", %{conv: conv} do
      assert {:block, _} = check(conv, "bash", %{"command" => "echo hi && curl http://example.com"})
    end

    test "allows other commands in auto mode", %{conv: conv} do
      assert :allow = check(conv, "bash", %{"command" => "echo hi"})
    end
  end

  describe "harness selection" do
    test "default harness is Workspace and carries the safety plugins" do
      assert Harness.default() == Harness.Workspace
      mods = Harness.Workspace.extensions() |> Enum.map(&if(is_tuple(&1), do: elem(&1, 0), else: &1))
      assert SuperPi.Plugins.Permissions in mods
      assert SuperPi.Plugins.ProtectedPaths in mods
      assert SuperPi.Plugins.ConfirmDestructive in mods
    end

    test "fetch/1 rejects an unknown harness" do
      assert {:error, {:unknown_harness, "agy"}} = Harness.fetch("agy")
      assert {:ok, Harness.Workspace} = Harness.fetch("super-pi-workspace")
    end

    test "fetch/1 uses the configured fallback" do
      Application.put_env(:super_pi, :fallback_harness, "super-pi-agent")
      on_exit(fn -> Application.delete_env(:super_pi, :fallback_harness) end)
      assert {:ok, Harness.Default} = Harness.fetch("agy")
    end
  end

  describe "gateway mode" do
    @opts Router.init([])

    defp chat(model, headers, extra \\ %{}) do
      payload = Map.merge(%{"model" => model, "messages" => [%{"role" => "user", "content" => "hi"}], "stream" => false}, extra)

      conn(:post, "/v1/chat/completions", Jason.encode!(payload))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-session-id", "perm-#{System.unique_integer([:positive])}")
      |> then(fn c -> Enum.reduce(headers, c, fn {k, v}, acc -> put_req_header(acc, k, v) end) end)
      |> Router.call(@opts)
    end

    defp mode_of(conn) do
      [sid] = get_req_header(conn, "x-session-id")
      id = conv_id_for(sid)
      Doc.snapshot("conversation", id, "pi.agent")["executionMode"]
    end

    defp conv_id_for(session) do
      [{^session, conv_id}] = :ets.lookup(:super_pi_gateway_sessions, session)
      conv_id
    end

    test "a Workspace session starts in accept-edits" do
      assert mode_of(chat("super-pi-workspace", [])) == "accept-edits"
    end

    test "a request can ask for plan mode" do
      assert mode_of(chat("super-pi-workspace", [{"x-super-pi-mode", "plan"}])) == "plan"
    end

    test "a request cannot ask for auto mode" do
      assert mode_of(chat("super-pi-workspace", [{"x-super-pi-mode", "auto"}])) == "accept-edits"
    end

    test "execution_mode body field works like the header" do
      assert mode_of(chat("super-pi-workspace", [], %{"execution_mode" => "plan"})) == "plan"
    end
  end

  describe "rpc session.open" do
    alias SuperPi.RPC.Server

    defp rpc(method, params) do
      payload = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params})
      {reply, _st, _} = Server.handle_rpc_payload(payload, Server.new_client_state())
      reply
    end

    test "a client cannot lift the policy through the agent map" do
      reply =
        rpc("session.open", %{
          "agent" => %{
            "dangerouslySkipPermissions" => true,
            "executionMode" => "auto",
            "settingsOverride" => %{"allowNonWorkspaceAccess" => true},
            "workspacePaths" => ["/"]
          }
        })

      agent = reply["result"]["agent"]
      assert agent["executionMode"] == "accept-edits"
      refute Map.get(agent, "dangerouslySkipPermissions")
      refute Map.has_key?(agent, "settingsOverride")
      assert agent["workspacePaths"] != ["/"]
    end

    test "a client can tighten the mode" do
      reply = rpc("session.open", %{"agent" => %{"executionMode" => "plan"}})
      assert reply["result"]["agent"]["executionMode"] == "plan"
    end

    test "session.configure is limited the same way" do
      conv_id = rpc("session.open", %{})["result"]["conversation_id"]
      reply = rpc("session.configure", %{"conversation_id" => conv_id, "agent" => %{"executionMode" => "auto", "dangerouslySkipPermissions" => true}})
      assert reply["result"]["agent"]["executionMode"] == "accept-edits"
      refute reply["result"]["agent"]["dangerouslySkipPermissions"]
    end

    test "an unknown harness is an error" do
      reply = rpc("session.open", %{"harness" => "agy"})
      assert reply["error"]["code"] == -32602
    end

    test "no harness name uses the default harness" do
      reply = rpc("session.open", %{})
      assert reply["result"]["agent"]["executionMode"] == "accept-edits"
    end
  end
end
