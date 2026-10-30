defmodule SuperPi.MCPTest do
  use SuperPi.DataCase, async: false

  alias SuperPi.MCP.Server

  setup do
    SuperPi.Tools.ensure_catalog_ets!()

    # These tests read and write files in the system temp dir, outside the workspace.
    # Direct tool calls now pass the permission policy, so they lift the confinement.
    saved = Application.fetch_env(:super_pi, :permissions)
    Application.put_env(:super_pi, :permissions, allowNonWorkspaceAccess: true)

    on_exit(fn ->
      case saved do
        {:ok, v} -> Application.put_env(:super_pi, :permissions, v)
        :error -> Application.delete_env(:super_pi, :permissions)
      end
    end)

    :ok
  end

  test "initialize handshake declares MCP tools, resources, and prompts" do
    req = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2024-11-05",
        "clientInfo" => %{"name" => "opencode", "version" => "1.0.0"}
      }
    }

    {:reply, reply, state} = Server.handle_mcp_line(Jason.encode!(req), %{})
    assert reply["jsonrpc"] == "2.0"
    assert reply["id"] == 1
    assert reply["result"]["serverInfo"]["name"] == "super-pi-beam"
    assert reply["result"]["capabilities"]["tools"]["listChanged"] == true
    assert state.client_info["name"] == "opencode"
  end

  test "ping returns empty result" do
    req = %{"jsonrpc" => "2.0", "id" => 2, "method" => "ping"}
    {:reply, reply, _state} = Server.handle_mcp_line(Jason.encode!(req), %{})
    assert reply["result"] == %{}
  end

  test "tools/list returns standard MCP schemas for all builtins and harness_task" do
    req = %{"jsonrpc" => "2.0", "id" => 3, "method" => "tools/list", "params" => %{}}
    {:reply, reply, _state} = Server.handle_mcp_line(Jason.encode!(req), %{})

    tools = reply["result"]["tools"]
    names = Enum.map(tools, & &1["name"])

    assert "read" in names
    assert "write" in names
    assert "edit" in names
    assert "bash" in names
    assert "grep" in names
    assert "find" in names
    assert "ls" in names
    assert "harness_task" in names

    read_tool = Enum.find(tools, &(&1["name"] == "read"))
    assert read_tool["inputSchema"]["type"] == "object"
    assert "path" in read_tool["inputSchema"]["required"]
  end

  test "tools/call executes tools safely and returns MCP content format" do
    tmp_path = Path.join(System.tmp_dir!(), "super_pi_mcp_test_#{System.unique_integer([:positive])}.txt")

    # 1. Write file
    write_req = %{
      "jsonrpc" => "2.0",
      "id" => 10,
      "method" => "tools/call",
      "params" => %{
        "name" => "write",
        "arguments" => %{"path" => tmp_path, "content" => "MCP integration with OpenCode"}
      }
    }

    {:reply, write_reply, _state} = Server.handle_mcp_line(Jason.encode!(write_req), %{})
    assert write_reply["result"]["isError"] == false
    assert [%{"text" => text, "type" => "text"}] = write_reply["result"]["content"]
    assert text =~ "Wrote"

    # 2. Read file
    read_req = %{
      "jsonrpc" => "2.0",
      "id" => 11,
      "method" => "tools/call",
      "params" => %{
        "name" => "read",
        "arguments" => %{"path" => tmp_path}
      }
    }

    {:reply, read_reply, _state} = Server.handle_mcp_line(Jason.encode!(read_req), %{})
    assert read_reply["result"]["isError"] == false
    assert [%{"text" => read_text}] = read_reply["result"]["content"]
    assert read_text == "MCP integration with OpenCode"

    # Clean up
    File.rm(tmp_path)
  end

  test "resources/list and resources/read return valid workspace context" do
    list_req = %{"jsonrpc" => "2.0", "id" => 20, "method" => "resources/list"}
    {:reply, list_reply, _state} = Server.handle_mcp_line(Jason.encode!(list_req), %{})
    assert length(list_reply["result"]["resources"]) >= 2

    read_req = %{
      "jsonrpc" => "2.0",
      "id" => 21,
      "method" => "resources/read",
      "params" => %{"uri" => "superpi://workspace/context"}
    }

    {:reply, read_reply, _state} = Server.handle_mcp_line(Jason.encode!(read_req), %{})
    assert [%{"text" => json_text, "uri" => "superpi://workspace/context"}] = read_reply["result"]["contents"]
    assert {:ok, _decoded} = Jason.decode(json_text)
  end
end
