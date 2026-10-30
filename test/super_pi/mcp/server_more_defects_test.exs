defmodule SuperPi.MCP.ServerMoreDefectsTest do
  @moduledoc """
  Regression tests that reproduce further MCP server defects found in the code
  review (mcp/server.ex). Every test is expected to FAIL on the current code and
  pass once the matching finding is fixed.

  Run only these:  mix test --only known_bug
  Skip these:      mix test --exclude known_bug
  """
  use SuperPi.DataCase, async: false

  alias SuperPi.MCP.Server

  defp call(method, params) do
    req = %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}
    {:reply, reply, _state} = Server.handle_mcp_line(Jason.encode!(req), %{})
    reply
  end

  defp machine_keys do
    SuperPi.Conversation.Locator.all()
    |> Enum.map(fn {id, _pid} -> {:conversation_machine, id} end)
    |> MapSet.new()
  end

  describe "harness_task leaks a linked Machine per call (mcp/server.ex:310-316)" do
    test "no conversation machine remains registered after the call returns" do
      before = machine_keys()

      reply =
        call("tools/call", %{"name" => "harness_task", "arguments" => %{"prompt" => "hello"}})

      assert reply["result"]["isError"] == false

      leaked = MapSet.difference(machine_keys(), before)
      assert MapSet.size(leaked) == 0, "leaked machines: #{inspect(MapSet.to_list(leaked))}"
    end
  end

  describe "advertised capabilities (mcp/server.ex:79-81,143-208)" do
    test "prompts/get is implemented for a prompt listed by prompts/list" do
      listed = call("prompts/list", %{})
      [%{"name" => name} | _] = listed["result"]["prompts"]

      reply = call("prompts/get", %{"name" => name, "arguments" => %{"goal" => "refactor"}})

      assert is_map(reply["result"]), "prompts/get failed: #{inspect(reply["error"])}"
      assert is_list(reply["result"]["messages"])
    end

    test "resources/read for an unknown URI is error -32002" do
      reply = call("resources/read", %{"uri" => "superpi://workspace/does-not-exist"})

      assert reply["error"]["code"] == -32002
    end

    for method <- ["tools/list", "resources/list", "prompts/list"] do
      test "#{method} rejects an invalid cursor with -32602" do
        reply = call(unquote(method), %{"cursor" => "bogus-cursor"})

        assert reply["error"]["code"] == -32602
      end
    end
  end
end
