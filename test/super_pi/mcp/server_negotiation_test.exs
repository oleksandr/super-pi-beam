defmodule SuperPi.MCP.ServerNegotiationTest do
  @moduledoc "`initialize` negotiates `protocolVersion` (D9)."
  # The debug-log test changes the global log level.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SuperPi.MCP.Server

  defp initialize(params) do
    req = %{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => params}
    {:reply, reply, state} = Server.handle_mcp_line(Jason.encode!(req), %{})
    {reply["result"]["protocolVersion"], state}
  end

  for version <- ["2025-06-18", "2025-03-26", "2024-11-05"] do
    test "answers the client's supported version #{version}" do
      assert {unquote(version), %{protocol_version: unquote(version)}} = initialize(%{"protocolVersion" => unquote(version)})
    end
  end

  test "answers the newest supported version for an unknown or newer one" do
    assert {"2025-06-18", _} = initialize(%{"protocolVersion" => "2026-07-28"})
    assert {"2025-06-18", _} = initialize(%{"protocolVersion" => "1999-01-01"})
  end

  test "answers the newest supported version when the client sends none or a non-string" do
    assert {"2025-06-18", _} = initialize(%{})
    assert {"2025-06-18", _} = initialize(%{"protocolVersion" => 20_250_618})
  end

  test "the ceiling is 2025-06-18, never 2026-07-28" do
    assert Server.supported_versions() == ["2025-06-18", "2025-03-26", "2024-11-05"]
  end

  @tag :capture_log
  test "logs the requested version at debug level" do
    previous = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous) end)

    log = capture_log([level: :debug], fn -> initialize(%{"protocolVersion" => "2026-07-28", "clientInfo" => %{"name" => "zed"}}) end)
    assert log =~ ~s(requested "2026-07-28")
    assert log =~ "answering 2025-06-18"
    assert log =~ ~s("zed")
  end
end
