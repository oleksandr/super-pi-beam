# A minimal AG-UI client for the Gateway: POST a run and print the event stream.
#
#   bin/super-pi gateway 4000 &
#   mix run examples/agui_client.exs "what is 15 plus 27?"
#
# Environment: SUPER_PI_URL (default http://127.0.0.1:4000), SUPER_PI_GATEWAY_TOKEN (when the gateway needs one),
# SUPER_PI_THREAD (thread id, default a fresh one). Reuse a thread id to continue a conversation.
#
# `@ag-ui/client`'s `HttpAgent` does the same thing in a browser: it POSTs a RunAgentInput and reads
# `text/event-stream`. This script prints text as it arrives, shows tool calls and state changes,
# and answers a permission request from the terminal through the input route.

base = System.get_env("SUPER_PI_URL", "http://127.0.0.1:4000")
thread = System.get_env("SUPER_PI_THREAD", "thread-#{System.unique_integer([:positive])}")
prompt = case Enum.join(System.argv(), " ") do "" -> "Say hello." ; text -> text end

headers =
  case System.get_env("SUPER_PI_GATEWAY_TOKEN") do
    nil -> []
    token -> [{"authorization", "Bearer " <> token}]
  end

defmodule AGUIClient do
  # The stream is `data: {json}\n\n` frames. A frame can span network chunks, so keep the tail.
  def handle_chunk(chunk, buffer, ctx) do
    {frames, rest} = chunk_frames(buffer <> chunk)
    Enum.each(frames, &handle_event(Jason.decode!(&1), ctx))
    rest
  end

  defp chunk_frames(data) do
    parts = String.split(data, "\n\n")
    {complete, [rest]} = Enum.split(parts, -1)
    {for("data: " <> json <- complete, do: json), rest}
  end

  defp handle_event(%{"type" => "RUN_STARTED", "runId" => run}, _), do: IO.puts("[run #{run}]")
  defp handle_event(%{"type" => "TEXT_MESSAGE_CONTENT", "delta" => d}, _), do: IO.write(d)
  defp handle_event(%{"type" => "TEXT_MESSAGE_END"}, _), do: IO.puts("")
  defp handle_event(%{"type" => "REASONING_MESSAGE_CONTENT", "delta" => d}, _), do: IO.write(IO.ANSI.faint() <> d <> IO.ANSI.reset())
  defp handle_event(%{"type" => "TOOL_CALL_START", "toolCallName" => n}, _), do: IO.puts("\n[tool] #{n}")
  defp handle_event(%{"type" => "TOOL_CALL_RESULT", "content" => c}, _), do: IO.puts("[result] " <> String.slice(c, 0, 120))
  defp handle_event(%{"type" => "STATE_DELTA", "delta" => ops}, _), do: IO.puts("[state] " <> Enum.map_join(ops, ", ", &"#{&1["path"]}=#{inspect(&1["value"])}"))
  defp handle_event(%{"type" => "RUN_FINISHED"}, _), do: IO.puts("[finished]")
  defp handle_event(%{"type" => "RUN_ERROR", "message" => m}, _), do: IO.puts("[error] #{m}")

  defp handle_event(%{"type" => "CUSTOM", "name" => "permission_request", "value" => v}, ctx) do
    IO.puts("\n[permission] #{v["toolName"]}: #{v["reason"]}")
    IO.puts("  options: allow_once, allow_always, reject_once, reject_always")
    option = IO.gets("option> ") |> to_string() |> String.trim()
    option = if option == "", do: "reject_once", else: option

    Req.post!("#{ctx.base}/agui/v1/sessions/#{v["conversationId"]}/input",
      json: %{"type" => "permission", "request_id" => v["requestId"], "option_id" => option},
      headers: ctx.headers
    )
  end

  defp handle_event(_other, _ctx), do: :ok
end

ctx = %{base: base, headers: headers}

Req.post!("#{base}/agui/v1/run",
  json: %{"threadId" => thread, "runId" => "run-1", "messages" => [%{"id" => "m1", "role" => "user", "content" => prompt}]},
  headers: headers,
  into: fn {:data, chunk}, {req, resp} ->
    buffer = Req.Request.get_private(req, :buffer, "")
    {:cont, {Req.Request.put_private(req, :buffer, AGUIClient.handle_chunk(chunk, buffer, ctx)), resp}}
  end,
  receive_timeout: 300_000
)
