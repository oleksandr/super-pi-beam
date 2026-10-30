defmodule SuperPi.MCP.ClientTest do
  @moduledoc "MCP client over stdio against a fake server (`test/support/fake_mcp_server.exs`)."
  use SuperPi.DataCase, async: false

  alias SuperPi.MCP.{Client, Manager}
  alias SuperPi.Tools
  alias SuperPi.TestSupport.Faults

  @script Path.expand("../../support/fake_mcp_server.exs", __DIR__)

  setup do
    Tools.ensure_catalog_ets!()
    Manager.create_tables()
    Manager.stop_all()
    on_exit(&Manager.stop_all/0)

    dir = Path.join(System.tmp_dir!(), "mcp_client_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  defp start_client(extra \\ []) do
    opts = [name: "fake", command: "elixir", args: [@script]] ++ extra
    {:ok, pid} = Client.start_link(opts)
    pid
  end

  defp write_config(dir, servers) do
    File.write!(Path.join(dir, "mcp_config.json"), Jason.encode!(%{"mcpServers" => servers}))
  end

  describe "Client" do
    test "handshake lists the tools of every page" do
      pid = start_client()
      assert :ok = Client.await_ready(pid, 15_000)
      assert pid |> Client.tools() |> Enum.map(& &1["name"]) == ["echo", "fail", "slow", "crash"]
    end

    test "call_tool returns the server result, and tolerates a banner and stderr output" do
      pid = start_client()
      :ok = Client.await_ready(pid, 15_000)

      assert {:ok, %{"content" => [%{"text" => "echo: hello"}]}} = Client.call_tool(pid, "echo", %{"text" => "hello"})
      assert {:ok, %{"isError" => true}} = Client.call_tool(pid, "fail", %{})
    end

    test "a protocol error is returned, not raised" do
      pid = start_client()
      :ok = Client.await_ready(pid, 15_000)
      assert {:error, {:protocol_error, %{"message" => message}}} = Client.call_tool(pid, "nope", %{})
      assert message =~ "unknown tool"
    end

    test "a call that exceeds the timeout returns {:error, :timeout} and the client stays usable" do
      pid = start_client()
      :ok = Client.await_ready(pid, 15_000)
      assert {:error, :timeout} = Client.call_tool(pid, "slow", %{}, 200)
      assert {:ok, _} = Client.call_tool(pid, "echo", %{"text" => "still here"})
    end

    test "a server that exits fails the call and stops the client" do
      pid = start_client()
      :ok = Client.await_ready(pid, 15_000)
      ref = Process.monitor(pid)
      assert {:error, {:server_exited, 3}} = Client.call_tool(pid, "crash", %{})
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
    end

    test "a missing command is an error" do
      Process.flag(:trap_exit, true)
      assert {:error, {:command_not_found, "definitely-not-a-command"}} =
               Client.start_link(name: "x", command: "definitely-not-a-command")
    end
  end

  describe "Manager" do
    test "starts enabled stdio servers, skips disabled and HTTP ones, and exposes namespaced tools", %{dir: dir} do
      write_config(dir, %{
        "fake srv" => %{"command" => "elixir", "args" => [@script]},
        "off" => %{"command" => "elixir", "args" => [@script], "disabled" => true},
        "remote" => %{"url" => "https://example.com/mcp"}
      })

      results = Manager.ensure_started(global_config_dir: dir)
      by_name = Map.new(results, &{&1.server, &1})

      assert %{status: :started, tools: 4} = by_name["fake srv"]
      assert %{status: {:error, :unsupported_transport}} = by_name["remote"]
      refute Map.has_key?(by_name, "off")

      assert Manager.tool_names() == [
               "mcp__fake_srv__crash",
               "mcp__fake_srv__echo",
               "mcp__fake_srv__fail",
               "mcp__fake_srv__slow"
             ]

      names = Tools.active_llm_tools() |> Enum.map(& &1["name"])
      assert "mcp__fake_srv__echo" in names
    end

    test "Tools.execute routes an MCP tool and maps the result", %{dir: dir} do
      write_config(dir, %{"fake" => %{"command" => "elixir", "args" => [@script]}})
      Manager.ensure_started(global_config_dir: dir)

      ok = Tools.execute("mcp__fake__echo", %{"text" => "hi"})
      assert ok["output"] == "echo: hi"
      assert ok["is_error"] == false
      assert ok["details"] == %{"mcp_server" => "fake", "mcp_tool" => "echo"}

      failed = Tools.execute("mcp__fake__fail", %{})
      assert failed["is_error"] == true
      assert failed["output"] == "boom"
    end

    test "an unknown MCP tool is an error result, not a raise" do
      result = Tools.execute("mcp__ghost__tool", %{})
      assert result["is_error"] == true
      assert result["output"] =~ "not available"
    end

    test "starting twice does not start a second process", %{dir: dir} do
      write_config(dir, %{"fake" => %{"command" => "elixir", "args" => [@script]}})
      assert [%{status: :started}] = Manager.ensure_started(global_config_dir: dir)
      assert [%{status: :running, tools: 4}] = Manager.ensure_started(global_config_dir: dir)
      assert length(DynamicSupervisor.which_children(SuperPi.MCPClientSupervisor)) == 1
    end

    test "a server that cannot start is reported and does not block the others", %{dir: dir} do
      write_config(dir, %{
        "bad" => %{"command" => "definitely-not-a-command"},
        "good" => %{"command" => "elixir", "args" => [@script]}
      })

      by_name = dir |> then(&Manager.ensure_started(global_config_dir: &1)) |> Map.new(&{&1.server, &1})
      assert %{status: {:error, _}} = by_name["bad"]
      assert %{status: :started} = by_name["good"]
    end

    test "stop_all removes the servers and their tools", %{dir: dir} do
      write_config(dir, %{"fake" => %{"command" => "elixir", "args" => [@script]}})
      Manager.ensure_started(global_config_dir: dir)
      assert Manager.tool_names() != []

      Manager.stop_all()
      assert Manager.tool_names() == []
      refute "mcp__fake__echo" in Enum.map(Tools.active_llm_tools(), & &1["name"])
      assert Tools.execute("mcp__fake__echo", %{})["is_error"] == true
    end

    test "tool names keep only characters that LLM APIs accept" do
      assert Manager.exposed_name("my server.v2", "do/it now") == "mcp__my_server_v2__do_it_now"
    end
  end

  describe "permissions" do
    defp check(mode, tool) do
      conv = SuperPi.Durable.Storage.create_conversation!(agent: %{"executionMode" => mode, "workspacePaths" => [File.cwd!()]})
      SuperPi.Plugins.Permissions.before_tool(tool, %{}, %{conversation_id: conv.id})
    end

    test "an MCP tool is blocked in accept-edits and allowed in auto" do
      assert {:block, _} = check("accept-edits", "mcp__fake__echo")
      assert :allow = check("auto", "mcp__fake__echo")
    end

    test "an MCP tool is blocked in plan mode" do
      assert {:block, _} = check("plan", "mcp__fake__echo")
    end
  end

  describe "conversation" do
    test "a conversation starts the configured servers and the model can call their tools", %{dir: dir} do
      write_config(dir, %{"fake" => %{"command" => "elixir", "args" => [@script]}})
      Application.put_env(:super_pi, :mcp_clients, true)
      on_exit(fn -> Application.put_env(:super_pi, :mcp_clients, false) end)

      conv = SuperPi.Durable.Storage.create_conversation!(agent: %{"globalConfigDir" => dir})
      me = self()
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      responder = fn payload, _ctx ->
        case Agent.get_and_update(calls, &{&1, &1 + 1}) do
          0 ->
            send(me, {:tools, inspect(payload.tools)})
            {:ok, Faults.tool_call_msg("c1", "mcp__fake__echo", %{"text" => "from model"})}

          _ ->
            send(me, {:messages, inspect(payload.messages)})
            {:ok, Faults.text_msg("done")}
        end
      end

      {:ok, pid} = SuperPi.Conversation.Machine.start_link(conversation_id: conv.id, extensions: [], llm_responder: responder)
      assert {:ok, _} = SuperPi.Conversation.Machine.submit(pid, "use the tool", timeout: 30_000)
      assert_received {:messages, messages}
      assert messages =~ "echo: from model"
      assert_received {:tools, tools}
      assert tools =~ "mcp__fake__echo"
    end
  end
end
