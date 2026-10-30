defmodule SuperPi.ReviewDefectsTest do
  @moduledoc """
  Regression tests for the review findings of Task 45 (note 26). Each test failed on the
  code before its fix.
  """
  use SuperPi.DataCase, async: false

  import Ecto.Query

  alias SuperPi.Auth
  alias SuperPi.Durable.{Doc, Storage, TaskEngine}
  alias SuperPi.Durable.Schemas.Task, as: TaskSchema
  alias SuperPi.MCP.Manager
  alias SuperPi.Plugins.{Handoff, Subagent}
  alias SuperPi.RPC.Server, as: RPC
  alias SuperPi.TestSupport.Faults

  @script Path.expand("../support/fake_mcp_server.exs", __DIR__)

  defp put_env(key, value) do
    old = Application.fetch_env(:super_pi, key)
    Application.put_env(:super_pi, key, value)

    on_exit(fn ->
      case old do
        {:ok, v} -> Application.put_env(:super_pi, key, v)
        :error -> Application.delete_env(:super_pi, key)
      end
    end)
  end

  describe "handoff child (high 1)" do
    test "inherits the parent's mode, workspace and settings, and the parent's owner" do
      settings = %{"permissions" => %{"deny" => ["command(curl)"]}}

      parent =
        Storage.create_conversation!(
          agent: %{"model" => "m", "executionMode" => "plan", "workspacePaths" => ["/srv/ws"], "settingsOverride" => settings}
        )

      Auth.claim!(parent.id, "alice")

      res = Handoff.wrap_tool("handoff", %{"goal" => "g", "summary" => "s"}, fn _ -> %{} end, %{conversation_id: parent.id})
      child_id = res["structured_output"]["child_conversation_id"]
      agent = Doc.snapshot("conversation", child_id, "pi.agent")

      assert agent["executionMode"] == "plan"
      assert agent["workspacePaths"] == ["/srv/ws"]
      assert agent["settingsOverride"] == settings
      assert agent["dangerouslySkipPermissions"] == false
      assert Auth.owner(child_id) == "alice"
    end

    test "a parent without a mode gives a child in accept-edits, never auto" do
      parent = Storage.create_conversation!(agent: %{})
      res = Handoff.wrap_tool("handoff", %{"goal" => "g", "summary" => "s"}, fn _ -> %{} end, %{conversation_id: parent.id})
      agent = Doc.snapshot("conversation", res["structured_output"]["child_conversation_id"], "pi.agent")
      assert agent["executionMode"] == "accept-edits"
    end
  end

  describe "InlineBash for remote callers (high 2)" do
    defp module_of(ext), do: if(is_tuple(ext), do: elem(ext, 0), else: ext)

    test "remote_extensions drops InlineBash, and the harness itself has it" do
      assert SuperPi.Plugins.InlineBash in Enum.map(SuperPi.Harness.Interactive.extensions([]), &module_of/1)
      refute SuperPi.Plugins.InlineBash in Enum.map(SuperPi.Harness.remote_extensions(SuperPi.Harness.Interactive), &module_of/1)
    end

    test "an RPC session on the interactive harness runs without InlineBash" do
      payload = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "session.open", "params" => %{"harness" => "super-pi-interactive"}})
      {%{"result" => %{"conversation_id" => conv_id}}, _, _} = RPC.handle_rpc_payload(payload, RPC.new_client_state())

      [{pid, _}] = Registry.lookup(SuperPi.Registry, {:conversation_machine, conv_id})
      {_state, data} = :gen_statem.call(pid, :get_state)
      refute SuperPi.Plugins.InlineBash in Enum.map(data.extensions, &module_of/1)
      on_exit(fn -> Process.exit(pid, :kill) end)
    end
  end

  describe "MCP harness_task (high 3)" do
    test "a turn that exceeds the timeout returns an error and the server keeps running" do
      put_env(:mcp_harness_task_timeout_ms, 300)
      put_env(:mcp_harness_task_opts, llm_responder: fn _p, _c -> Process.sleep(3_000) && {:ok, Faults.text_msg("late")} end)
      SuperPi.Tools.ensure_catalog_ets!()

      req = %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/call", "params" => %{"name" => "harness_task", "arguments" => %{"prompt" => "slow"}}}
      assert {:reply, %{"result" => result}, _state} = SuperPi.MCP.Server.handle_mcp_line(Jason.encode!(req), %{})

      assert result["isError"] == true
      assert [%{"text" => text}] = result["content"]
      assert text =~ "timed out"
    end

    test "a machine that crashes does not crash the caller" do
      put_env(:mcp_harness_task_opts, llm_responder: fn _p, _c -> exit(:boom) end)
      SuperPi.Tools.ensure_catalog_ets!()

      req = %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/call", "params" => %{"name" => "harness_task", "arguments" => %{"prompt" => "x"}}}
      assert {:reply, %{"result" => %{"isError" => true}}, _} = SuperPi.MCP.Server.handle_mcp_line(Jason.encode!(req), %{})
    end
  end

  describe "MCP launch failure (high 4)" do
    setup do
      Manager.create_tables()
      Manager.stop_all()
      on_exit(&Manager.stop_all/0)
      dir = Path.join(System.tmp_dir!(), "rd_mcp_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      %{dir: dir}
    end

    test "a server that never answers is stopped, with its OS process", %{dir: dir} do
      marker = "marker-#{System.unique_integer([:positive])}"
      put_env(:mcp_startup_timeout_ms, 600)

      File.write!(
        Path.join(dir, "mcp_config.json"),
        Jason.encode!(%{"mcpServers" => %{"stuck" => %{"command" => "elixir", "args" => [@script, marker], "env" => %{"FAKE_MCP_MODE" => "hang"}}}})
      )

      assert [%{status: {:error, :timeout}}] = Manager.ensure_started(global_config_dir: dir)
      assert DynamicSupervisor.which_children(SuperPi.MCPClientSupervisor) == []

      survivors =
        Enum.reduce_while(1..20, nil, fn _, _ ->
          case System.cmd("pgrep", ["-f", marker]) do
            {_, 0} -> Process.sleep(100) && {:cont, :alive}
            _ -> {:halt, :gone}
          end
        end)

      assert survivors == :gone, "the stuck server's OS process is still running"
    end

    test "two callers launch one server", %{dir: dir} do
      File.write!(Path.join(dir, "mcp_config.json"), Jason.encode!(%{"mcpServers" => %{"fake" => %{"command" => "elixir", "args" => [@script]}}}))

      results = 1..4 |> Task.async_stream(fn _ -> Manager.ensure_started(global_config_dir: dir) end, timeout: 30_000) |> Enum.flat_map(fn {:ok, r} -> r end)

      assert Enum.count(results, &(&1.status == :started)) == 1
      assert length(DynamicSupervisor.which_children(SuperPi.MCPClientSupervisor)) == 1
    end
  end

  describe "killed subagent (high 5)" do
    test "a child stuck outside its deadline is failed, and the parent turn is not left waiting" do
      put_env(:subagent_kill_slack_ms, 100)
      dir = Path.join(System.tmp_dir!(), "rd_sub_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      put_env(:mcp_startup_timeout_ms, 4_000)
      put_env(:mcp_clients, true)
      on_exit(&Manager.stop_all/0)

      File.write!(
        Path.join(dir, "mcp_config.json"),
        Jason.encode!(%{"mcpServers" => %{"stuck" => %{"command" => "elixir", "args" => [@script], "env" => %{"FAKE_MCP_MODE" => "hang"}}}})
      )

      parent = Storage.create_conversation!(agent: %{"model" => "m", "executionMode" => "accept-edits", "globalConfigDir" => dir})
      {:ok, task} = TaskEngine.create_task(parent.id, "pi.generation")
      {:ok, running} = TaskEngine.start_task(task.id)

      res =
        Subagent.wrap_tool(
          "delegate_subagent",
          %{"role" => "scout", "prompt" => "x", "timeout_ms" => 200},
          fn _ -> %{} end,
          %{conversation_id: parent.id, active_task_id: running.id}
        )

      assert [%{"status" => "failed"}] = res["structured_output"]["subagents"]
      assert [%{status: "failed"}] = Repo.all(from t in TaskSchema, where: t.kind == "pi.subagent")

      # The parent can now complete: no live child holds it in `completing`.
      assert {:ok, %{status: "completed"}} = TaskEngine.complete_task(running.id, %{})
    end
  end

  describe "subagent timeout cap (medium)" do
    test "the model cannot raise the timeout above the configured limit" do
      put_env(:subagent_timeout_ms, 300)
      parent = Storage.create_conversation!(agent: %{"model" => "m"})
      slow = fn _p, _c -> Process.sleep(3_000) && {:ok, Faults.text_msg("late")} end

      {micros, res} =
        :timer.tc(fn ->
          Subagent.wrap_tool("delegate_subagent", %{"role" => "scout", "prompt" => "x", "timeout_ms" => 1_000_000}, fn _ -> %{} end, %{
            conversation_id: parent.id,
            config: [machine_opts: [llm_responder: slow]]
          })
        end)

      assert [%{"status" => "failed", "error" => error}] = res["structured_output"]["subagents"]
      assert error =~ "timed out"
      assert div(micros, 1000) < 2_500
    end
  end
end
