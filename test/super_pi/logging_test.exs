defmodule SuperPi.LoggingTest do
  @moduledoc "Log lines from a conversation carry its conversation and task id."
  use SuperPi.DataCase, async: false

  alias SuperPi.Conversation.Machine
  alias SuperPi.Durable.Storage
  alias SuperPi.TestSupport.Faults

  test "the machine process has conversation_id and, during a turn, task_id metadata" do
    conv = Storage.create_conversation!()
    me = self()

    responder = fn _payload, _ctx ->
      send(me, {:metadata, Logger.metadata()})
      {:ok, Faults.text_msg("ok")}
    end

    {:ok, pid} = Machine.start_link(conversation_id: conv.id, extensions: [], llm_responder: responder)
    assert {:ok, _} = Machine.submit(pid, "hi", timeout: 10_000)

    assert_received {:metadata, metadata}
    assert metadata[:conversation_id] == conv.id
    assert is_integer(metadata[:task_id])
  end

  test "the default formatter prints the ids" do
    formatter = Application.get_env(:logger, :default_formatter)
    assert :conversation_id in formatter[:metadata]
    assert :task_id in formatter[:metadata]
  end

  test "library code does not print to stdout (the MCP protocol stream is the only exception)" do
    offenders =
      Path.wildcard("lib/**/*.ex")
      |> Enum.reject(&(&1 in ["lib/super_pi/cli.ex", "lib/super_pi/mcp/server.ex"]))
      |> Enum.filter(fn file -> File.read!(file) =~ ~r/^\s*(?!#)[^#\n]*\bIO\.(puts|inspect|write)\(/m end)

    assert offenders == [], "use Logger instead of IO in: #{inspect(offenders)}"
  end
end
