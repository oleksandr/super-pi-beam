# A minimal ACP client: starts `bin/super-pi acp` as a subprocess, creates a session, sends one
# prompt, prints the streamed text, and answers a permission request from the terminal.
#
#   mix run examples/acp_client.exs "list the files in this directory"
#
# What an editor does, in 100 lines. The agent is a subprocess and the protocol is JSON-RPC 2.0,
# one JSON object per line on its stdin and stdout.

defmodule ACPClient do
  def run(prompt) do
    agent = Path.expand("../bin/super-pi", __DIR__)
    port = Port.open({:spawn_executable, System.find_executable("bash")}, [:binary, :exit_status, {:line, 1_000_000}, args: [agent, "acp"]])

    send_msg(port, %{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => %{"protocolVersion" => 1, "clientCapabilities" => %{}}})
    %{"result" => init} = await_result(port, 1)
    IO.puts("agent: #{init["agentInfo"]["title"]}, harnesses: #{Enum.map_join(init["_meta"]["superPi"]["harnesses"], ", ", & &1["id"])}")

    send_msg(port, %{"jsonrpc" => "2.0", "id" => 2, "method" => "session/new", "params" => %{"cwd" => File.cwd!(), "mcpServers" => []}})
    %{"result" => %{"sessionId" => session_id}} = await_result(port, 2)

    send_msg(port, %{"jsonrpc" => "2.0", "id" => 3, "method" => "session/prompt", "params" => %{"sessionId" => session_id, "prompt" => [%{"type" => "text", "text" => prompt}]}})
    %{"result" => %{"stopReason" => reason}} = await_result(port, 3)
    IO.puts("\n[stop: #{reason}]")
    Port.close(port)
  end

  # Reads agent messages until the response to `id`. Prints updates and answers permission requests.
  defp await_result(port, id) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        case Jason.decode(line) do
          {:ok, %{"id" => ^id, "result" => _} = msg} -> msg
          {:ok, msg} -> handle(port, msg); await_result(port, id)
          _ -> await_result(port, id)
        end

      {^port, {:exit_status, status}} ->
        raise "agent exited with #{status}"
    end
  end

  defp handle(_port, %{"method" => "session/update", "params" => %{"update" => %{"sessionUpdate" => "agent_message_chunk", "content" => %{"text" => text}}}}), do: IO.write(text)
  defp handle(_port, %{"method" => "session/update", "params" => %{"update" => %{"sessionUpdate" => "tool_call", "title" => title}}}), do: IO.puts("\n[tool] #{title}")

  defp handle(port, %{"method" => "session/request_permission", "id" => req_id, "params" => %{"toolCall" => call, "options" => options}}) do
    IO.puts("\n[permission] #{call["title"]}")
    Enum.each(options, &IO.puts("  #{&1["optionId"]}: #{&1["name"]}"))
    choice = IO.gets("option> ") |> to_string() |> String.trim()
    option = if choice in Enum.map(options, & &1["optionId"]), do: choice, else: "reject_once"
    send_msg(port, %{"jsonrpc" => "2.0", "id" => req_id, "result" => %{"outcome" => %{"outcome" => "selected", "optionId" => option}}})
  end

  defp handle(_port, _other), do: :ok

  defp send_msg(port, map), do: Port.command(port, Jason.encode!(map) <> "\n")
end

ACPClient.run(Enum.join(System.argv(), " ") |> then(&if(&1 == "", do: "Say hello.", else: &1)))
