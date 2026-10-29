defmodule SuperPi.MCP.ServerDefectsTest do
  @moduledoc """
  Regression tests that reproduce MCP server defects found in the code review
  (see vault note "20 - Codebase Review Findings"). Every test is expected to
  FAIL on the current code and pass once the matching finding is fixed.

  Run only these:  mix test --only known_bug
  Skip these:      mix test --exclude known_bug
  """
  use ExUnit.Case, async: false

  alias SuperPi.MCP.Server

  @moduletag :known_bug

  setup do
    SuperPi.Tools.ensure_catalog_ets!()
    :ok
  end

  defp call(request) do
    {:ok, Server.handle_mcp_line(Jason.encode!(request), %{})}
  rescue
    e -> {:raised, e}
  end

  defp rpc(id, method, params), do: %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

  describe "malformed requests must produce JSON-RPC errors, not raise (mcp/server.ex:55-140)" do
    @bad_requests [
      {"initialize with null params", "initialize", nil},
      {"initialize with list params", "initialize", []},
      {"tools/call with null arguments", "tools/call", %{"name" => "read", "arguments" => nil}},
      {"tools/call with list arguments", "tools/call", %{"name" => "read", "arguments" => []}},
      {"tools/call with a non-string tool name", "tools/call", %{"name" => 123, "arguments" => %{}}},
      {"tools/call with a non-string path", "tools/call", %{"name" => "read", "arguments" => %{"path" => 123}}}
    ]

    for {label, method, params} <- @bad_requests do
      test label do
        outcome = call(rpc(1, unquote(method), unquote(Macro.escape(params))))

        assert {:ok, {:reply, reply, _state}} = outcome, "handler raised: #{inspect(outcome)}"

        # A tool-level failure may legitimately be reported as an isError result.
        assert is_map(reply["error"]) or get_in(reply, ["result", "isError"]) == true,
               "expected an error reply, got: #{inspect(reply)}"
      end
    end

    @missing_params [
      {"tools/call without a name", "tools/call", %{"arguments" => %{}}},
      {"tools/call with null params", "tools/call", nil},
      {"resources/read without a uri", "resources/read", %{}}
    ]

    for {label, method, params} <- @missing_params do
      test "#{label} is -32602 (invalid params), not -32601 (method not found)" do
        {:ok, {:reply, reply, _}} = call(rpc(1, unquote(method), unquote(Macro.escape(params))))
        assert reply["error"]["code"] == -32602
      end
    end
  end

  describe "notifications get no reply (mcp/server.ex:57-60,206)" do
    for method <- ["notifications/cancelled", "notifications/roots/list_changed", "notifications/progress"] do
      test method do
        request = %{"jsonrpc" => "2.0", "method" => unquote(method), "params" => %{}}
        assert {:noreply, _state} = Server.handle_mcp_line(Jason.encode!(request), %{})
      end
    end
  end

  describe "tool output must be JSON-encodable (mcp/server.ex:37, sandbox_runner.ex:130)" do
    test "reading a file with invalid UTF-8 still yields an encodable reply" do
      path = Path.join(System.tmp_dir!(), "mcp_bin_#{System.unique_integer([:positive])}.bin")
      File.write!(path, <<255, 254, 253, 0, 200>>)
      on_exit(fn -> File.rm(path) end)

      {:ok, {:reply, reply, _}} = call(rpc(1, "tools/call", %{"name" => "read", "arguments" => %{"path" => path}}))

      assert {:ok, _json} = Jason.encode(reply),
             "run_stdio would crash in Jason.encode!/1 on this reply"
    end
  end
end
