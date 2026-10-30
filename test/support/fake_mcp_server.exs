# A minimal MCP server over stdio for tests. Plain Elixir, no dependencies (OTP `:json`).
# Tools: echo, fail (isError), slow (2 s), crash (exits with status 3). `tools/list` has two pages.
defmodule FakeMCP do
  def run do
    # A banner on stdout is not JSON; a client must ignore it.
    IO.puts("fake mcp server starting")
    loop()
  end

  defp loop do
    case IO.gets("") do
      :eof -> :ok
      {:error, _} -> :ok
      line -> line |> String.trim() |> handle(); loop()
    end
  end

  defp handle(""), do: :ok

  defp handle(line) do
    case :json.decode(line) do
      %{"method" => "initialize", "id" => id} ->
        reply(id, %{
          "protocolVersion" => "2024-11-05",
          "capabilities" => %{"tools" => %{}},
          "serverInfo" => %{"name" => "fake", "version" => "1.0.0"}
        })

      %{"method" => "notifications/initialized"} ->
        :ok

      %{"method" => "tools/list", "id" => id} = msg ->
        case get_in(msg, ["params", "cursor"]) do
          nil -> reply(id, %{"tools" => [tool("echo", "Echo the text"), tool("fail", "Always fails")], "nextCursor" => "p2"})
          "p2" -> reply(id, %{"tools" => [tool("slow", "Sleeps"), tool("crash", "Exits")]})
        end

      %{"method" => "tools/call", "id" => id, "params" => %{"name" => name} = params} ->
        call(id, name, Map.get(params, "arguments", %{}))

      %{"method" => "ping", "id" => id} ->
        reply(id, %{})

      %{"id" => id} ->
        send_json(%{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => -32601, "message" => "unknown method"}})

      _ ->
        :ok
    end
  end

  defp call(id, "echo", args), do: reply(id, %{"content" => [%{"type" => "text", "text" => "echo: " <> to_string(args["text"])}]})
  defp call(id, "fail", _), do: reply(id, %{"content" => [%{"type" => "text", "text" => "boom"}], "isError" => true})
  defp call(id, "slow", _), do: (Process.sleep(2_000); reply(id, %{"content" => [%{"type" => "text", "text" => "late"}]}))
  defp call(_id, "crash", _), do: System.halt(3)

  defp call(id, name, _) do
    send_json(%{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => -32602, "message" => "unknown tool: " <> name}})
  end

  defp tool(name, description) do
    %{"name" => name, "description" => description, "inputSchema" => %{"type" => "object", "properties" => %{"text" => %{"type" => "string"}}}}
  end

  defp reply(id, result), do: send_json(%{"jsonrpc" => "2.0", "id" => id, "result" => result})
  defp send_json(map), do: IO.puts(IO.iodata_to_binary(:json.encode(map)))
end

FakeMCP.run()
