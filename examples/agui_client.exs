# An AG-UI terminal client for the Gateway. It shows what a web front end gets from /agui/v1.
#
#   bin/super-pi gateway 4000 &
#   mix run examples/agui_client.exs "what is 15 plus 27?"     # one run
#   mix run examples/agui_client.exs                           # REPL: every line is a run on one thread
#
# What it renders, all from the one SSE stream:
#   - streamed text and reasoning (TEXT_MESSAGE_*, REASONING_*)
#   - tool calls as cards: arguments, run time, result (TOOL_CALL_*)
#   - a client-side state store: STATE_SNAPSHOT plus STATE_DELTA applied as JSON Patch.
#     Status, plan checklist and token usage come from it.
#   - CUSTOM events: permission requests, questions (ask_question), notices, subagents
#   - a summary per run, with a tally of the AG-UI events received
#
# The client answers prompts through POST /agui/v1/sessions/:id/input.
#
# Environment:
#   SUPER_PI_URL            gateway base URL (default http://127.0.0.1:4000)
#   SUPER_PI_GATEWAY_TOKEN  bearer token, when the gateway needs one
#   SUPER_PI_THREAD         thread id (default: a fresh one). Reuse it to continue a conversation.
#   SUPER_PI_HARNESS        forwardedProps.harness, for example super-pi-planner
#   SUPER_PI_MODE           forwardedProps.executionMode
#   SUPER_PI_RAW=1          also print every raw frame
#
# A prompt that uses most of the stream: "Plan three steps with the todo tool, list the files
# here, read mix.exs, then ask me with ask_question which dependency to explain."
#
# `@ag-ui/client`'s `HttpAgent` does the same in a browser: POST a RunAgentInput, read text/event-stream.

defmodule AGUIClient do
  @moduledoc false

  # --- Entry ---

  def main(argv) do
    base = System.get_env("SUPER_PI_URL", "http://127.0.0.1:4000")
    thread = System.get_env("SUPER_PI_THREAD", "thread-#{System.unique_integer([:positive])}")

    headers =
      case System.get_env("SUPER_PI_GATEWAY_TOKEN") do
        nil -> []
        token -> [{"authorization", "Bearer " <> token}]
      end

    {:ok, store} = Agent.start_link(fn -> new_state(base, headers, thread) end)

    banner(base, thread)

    case Enum.join(argv, " ") do
      "" -> repl(store, 1)
      prompt -> run(store, prompt, 1)
    end
  end

  defp repl(store, n) do
    IO.write(paint([:bright, :green], "you> "))

    case IO.gets("") do
      :eof -> IO.puts("")
      {:error, _} -> IO.puts("")
      line ->
        case String.trim(line) do
          "" -> repl(store, n)
          cmd when cmd in ["exit", "quit", "/exit", "/quit"] -> :ok
          prompt -> run(store, prompt, n) && repl(store, n + 1)
        end
    end
  end

  defp run(store, prompt, n) do
    st = Agent.get(store, & &1)
    props = for {k, env} <- [{"harness", "SUPER_PI_HARNESS"}, {"executionMode", "SUPER_PI_MODE"}], v = System.get_env(env), into: %{}, do: {k, v}

    body = %{
      "threadId" => st.thread,
      "runId" => "run-#{n}",
      "messages" => [%{"id" => "m#{n}", "role" => "user", "content" => prompt}],
      "forwardedProps" => props
    }

    Agent.update(store, &%{&1 | buffer: "", tally: %{}, calls: %{}, open: nil, bol: true, tools: 0})

    result =
      Req.post("#{st.base}/agui/v1/run",
        json: body,
        headers: st.headers,
        retry: false,
        receive_timeout: 300_000,
        into: fn {:data, chunk}, acc ->
          # Run `feed` here, not inside the Agent: a prompt can wait longer than the Agent call timeout.
          next = feed(Agent.get(store, & &1), chunk)
          Agent.update(store, fn _ -> next end)
          {:cont, acc}
        end
      )

    case result do
      {:ok, %{status: 200}} ->
        true

      {:ok, %{status: status, body: body}} ->
        IO.puts(paint([:red], "HTTP #{status}: #{inspect(body)}"))
        false

      {:error, reason} ->
        IO.puts(paint([:red], "Request failed: #{Exception.message(reason)}"))
        false
    end
  end

  defp new_state(base, headers, thread) do
    %{base: base, headers: headers, thread: thread, buffer: "", state: %{}, tally: %{}, calls: %{},
      open: nil, bol: true, t0: nil, tools: 0, raw: System.get_env("SUPER_PI_RAW") == "1"}
  end

  defp banner(base, thread) do
    IO.puts(paint([:bright, :cyan], "╭─ super-pi · AG-UI"))
    IO.puts(paint([:cyan], "│ ") <> paint(:faint, "#{base}/agui/v1/run   thread #{thread}"))
    IO.puts(paint([:cyan], "╰─") <> "\n")
  end

  # --- Frames ---
  # The stream is `data: {json}\n\n` frames. A frame can span network chunks, so keep the tail.

  defp feed(st, chunk) do
    parts = String.split(st.buffer <> chunk, "\n\n")
    {complete, [rest]} = Enum.split(parts, -1)

    for("data: " <> json <- complete, do: json)
    |> Enum.reduce(%{st | buffer: rest}, fn json, st ->
      if st.raw, do: IO.puts(paint(:faint, "  « " <> json))
      event = Jason.decode!(json)
      st = %{st | tally: Map.update(st.tally, event["type"], 1, &(&1 + 1))}
      handle(event, st)
    end)
  end

  # --- Lifecycle ---

  defp handle(%{"type" => "RUN_STARTED", "runId" => run}, st) do
    line(%{st | t0: System.monotonic_time(:millisecond)}, paint([:bright, :blue], "━━ run #{run} ") <> paint(:faint, String.duplicate("━", 40)))
  end

  defp handle(%{"type" => "RUN_FINISHED"}, st), do: finish(st, paint([:bright, :green], "✔ finished"))

  defp handle(%{"type" => "RUN_ERROR"} = e, st) do
    label = if e["code"] == "cancelled", do: "■ cancelled", else: "✖ error: #{e["message"]}"
    finish(st, paint([:bright, :red], label))
  end

  # --- Text and reasoning ---

  defp handle(%{"type" => "TEXT_MESSAGE_START"}, st),
    do: line(st, paint([:bright, :cyan], "◆ assistant")) |> Map.put(:open, :text)

  defp handle(%{"type" => "TEXT_MESSAGE_CONTENT", "delta" => d}, st), do: stream(st, "  ", [], d)
  defp handle(%{"type" => "TEXT_MESSAGE_END"}, st), do: close(st)

  defp handle(%{"type" => "REASONING_START"}, st),
    do: line(st, paint([:faint], "┊ thinking")) |> Map.put(:open, :reasoning)

  defp handle(%{"type" => "REASONING_MESSAGE_CONTENT", "delta" => d}, st), do: stream(st, paint(:faint, "┊ "), [:faint, :italic], d)
  defp handle(%{"type" => "REASONING_END"}, st), do: close(st)

  # --- Tool calls ---
  # AG-UI's TOOL_CALL_END means "arguments complete". The tool runs after it. TOOL_CALL_RESULT ends the card.

  defp handle(%{"type" => "TOOL_CALL_START", "toolCallId" => id, "toolCallName" => name}, st) do
    st = close(st) |> line(paint([:bright, :yellow], "╭─ ⚙ #{name}"))
    put_in(st.calls[id], %{name: name, args: "", t0: System.monotonic_time(:millisecond)})
  end

  defp handle(%{"type" => "TOOL_CALL_ARGS", "toolCallId" => id, "delta" => d}, st),
    do: update_in(st.calls[id], &Map.update!(&1 || %{name: "?", args: "", t0: 0}, :args, fn a -> a <> d end))

  defp handle(%{"type" => "TOOL_CALL_END", "toolCallId" => id}, st) do
    case st.calls[id] do
      %{args: args} -> line(st, paint(:yellow, "│ ") <> paint(:faint, summarize_args(args)))
      _ -> st
    end
  end

  defp handle(%{"type" => "TOOL_CALL_RESULT", "toolCallId" => id, "content" => content}, st) do
    ms = System.monotonic_time(:millisecond) - (get_in(st.calls, [id, :t0]) || System.monotonic_time(:millisecond))
    blocked? = String.starts_with?(content, "Blocked:")
    {mark, color} = if blocked?, do: {"✖", [:bright, :red]}, else: {"✓", [:bright, :green]}

    st = %{st | tools: st.tools + 1}

    st =
      Enum.reduce(preview(content), st, fn l, st ->
        line(st, paint(:yellow, "│ ") <> paint(if(blocked?, do: :red, else: :white), l))
      end)

    line(st, paint(:yellow, "╰─ ") <> paint(color, mark) <> paint(:faint, " #{ms} ms"))
  end

  # --- State: STATE_SNAPSHOT replaces, STATE_DELTA is a JSON Patch ---

  defp handle(%{"type" => "STATE_SNAPSHOT", "snapshot" => snap}, st) do
    st = %{st | state: snap}
    meta = for {label, key} <- [{"model", "model"}, {"mode", "mode"}], v = snap[key], do: "#{label} #{v}"
    if meta == [], do: st, else: line(st, paint(:faint, "· " <> Enum.join(meta, " · ")))
  end

  defp handle(%{"type" => "STATE_DELTA", "delta" => ops}, st) do
    {:ok, next} = Jsonpatch.apply_patch(ops, st.state)
    st = %{st | state: next}
    show_changes(st, ops, next)
  end

  defp handle(%{"type" => "MESSAGES_SNAPSHOT", "messages" => m}, st),
    do: line(close(st), paint(:faint, "⟲ messages snapshot (#{length(m)} messages)"))

  # --- CUSTOM ---

  defp handle(%{"type" => "CUSTOM", "name" => "permission_request", "value" => v}, st) do
    st = close(st)
    IO.puts(paint([:bright, :magenta], "┌─ permission needed: #{v["toolName"]}") <> paint(:faint, "  risk: #{v["risk"]}"))
    IO.puts(paint(:magenta, "│ ") <> to_string(v["reason"]))
    IO.puts(paint(:magenta, "│ ") <> paint(:faint, summarize_args(Jason.encode!(v["arguments"] || %{}))))
    IO.puts(paint(:magenta, "│ ") <> "[1] allow once  [2] always allow  [3] reject  [4] always reject")
    IO.write(paint(:magenta, "└─ ") <> "choice> ")

    option =
      case read_line() do
        "1" -> "allow_once"
        "2" -> "allow_always"
        "4" -> "reject_always"
        _ -> "reject_once"
      end

    respond(st, v, %{"type" => "permission", "request_id" => v["requestId"], "option_id" => option})
    %{st | bol: true}
  end

  defp handle(%{"type" => "CUSTOM", "name" => "ui_request", "value" => %{"questions" => qs} = v}, st) do
    st = close(st)

    answers =
      for q <- qs do
        IO.puts(paint([:bright, :magenta], "┌─ question ") <> q["question"])
        opts = q["options"] || []
        opts |> Enum.with_index(1) |> Enum.each(fn {o, i} -> IO.puts(paint(:magenta, "│ ") <> "[#{i}] #{o}") end)
        IO.write(paint(:magenta, "└─ ") <> "choice> ")
        pick = read_line()

        selected =
          case Integer.parse(pick) do
            {i, ""} when i >= 1 and i <= length(opts) -> Enum.at(opts, i - 1)
            _ -> if pick == "", do: List.first(opts), else: pick
          end

        %{"question" => q["question"], "selected" => selected}
      end

    respond(st, v, %{"type" => "answer", "request_id" => v["requestId"], "value" => answers})
    %{st | bol: true}
  end

  defp handle(%{"type" => "CUSTOM", "name" => "notice", "value" => v}, st) do
    color = %{"error" => [:bright, :red], "warning" => [:yellow]}[v["level"]] || [:faint]
    line(close(st), paint(color, "ℹ #{v["message"]}"))
  end

  defp handle(%{"type" => "CUSTOM", "name" => "subagent_started", "value" => v}, st),
    do: line(close(st), paint([:bright, :blue], "⎇ subagent #{v["role"]}: ") <> paint(:faint, truncate(to_string(v["task"]), 100)))

  defp handle(%{"type" => "CUSTOM", "name" => "subagent_finished", "value" => v}, st),
    do: line(close(st), paint([:bright, :blue], "⎇ subagent #{v["status"]}: ") <> paint(:faint, truncate(to_string(v["summary"]), 100)))

  defp handle(%{"type" => "CUSTOM", "name" => "stream_reset", "value" => v}, st),
    do: line(close(st), paint(:yellow, "↻ stream reset, retry in #{v["retryInMs"]} ms"))

  defp handle(%{"type" => "CUSTOM", "name" => "tool_blocked"}, st), do: st
  defp handle(%{"type" => "CUSTOM", "name" => "ui_resolved"}, st), do: st
  defp handle(_other, st), do: st

  # --- State rendering ---

  defp show_changes(st, ops, next) do
    paths = Enum.map(ops, & &1["path"])

    st =
      case Enum.find(ops, &(&1["path"] == "/status")) do
        %{"value" => status} when status != "idle" -> line(close(st), paint(:faint, "· #{status}"))
        _ -> st
      end

    if Enum.any?(paths, &String.starts_with?(&1, "/plan")), do: plan(close(st), next["plan"] || []), else: st
  end

  defp plan(st, []), do: st

  defp plan(st, entries) do
    done = Enum.count(entries, & &1["completed"])
    st = line(st, paint([:bright, :blue], "┌─ plan ") <> paint(:faint, "#{done}/#{length(entries)}"))

    st =
      Enum.reduce(entries, st, fn e, st ->
        {box, style} = if e["completed"], do: {"☑", [:green]}, else: {"☐", [:white]}
        line(st, paint(:blue, "│ ") <> paint(style, "#{box} #{e["text"]}"))
      end)

    line(st, paint(:blue, "└─"))
  end

  defp finish(st, label) do
    st = close(st)
    ms = if st.t0, do: System.monotonic_time(:millisecond) - st.t0, else: 0
    usage = st.state["usage"] || %{}

    parts = [
      "#{Float.round(ms / 1000, 1)} s",
      "#{usage["inputTokens"] || 0} in / #{usage["outputTokens"] || 0} out tokens",
      "#{st.tools} tool call#{if st.tools == 1, do: "", else: "s"}"
    ]

    tally = st.tally |> Enum.sort_by(&elem(&1, 0)) |> Enum.map_join("  ", fn {t, n} -> "#{t}×#{n}" end)

    st = line(st, label <> paint(:faint, " · " <> Enum.join(parts, " · ")))
    line(st, paint(:faint, "  events: " <> tally)) |> line("")
  end

  # --- Output helpers: `bol` is true at the start of a line ---

  defp line(st, text) do
    st = newline(st)
    IO.puts(text)
    st
  end

  defp newline(%{bol: true} = st), do: st

  defp newline(st) do
    IO.puts("")
    %{st | bol: true}
  end

  defp close(st), do: newline(%{st | open: nil})

  defp stream(st, gutter, style, delta) do
    delta
    |> String.split("\n")
    |> Enum.with_index()
    |> Enum.reduce(st, fn {part, i}, st ->
      st = if i > 0, do: newline(%{st | bol: false}), else: st

      if part == "" do
        st
      else
        if st.bol, do: IO.write(gutter)
        IO.write(paint(style, part))
        %{st | bol: false}
      end
    end)
  end

  defp paint(style, text) do
    [List.wrap(style), text] |> IO.ANSI.format() |> IO.chardata_to_string()
  end

  defp summarize_args(json) do
    case Jason.decode(json) do
      {:ok, %{} = map} when map_size(map) > 0 ->
        Enum.map_join(map, "  ", fn {k, v} -> "#{k}=#{truncate(inline(v), 70)}" end)

      {:ok, other} when other not in [%{}, nil] ->
        truncate(inline(other), 140)

      _ ->
        truncate(json, 140)
    end
  end

  defp inline(v) when is_binary(v), do: v |> String.replace("\n", "⏎") |> inspect()
  defp inline(v), do: Jason.encode!(v)

  defp preview(content) do
    lines = content |> String.split("\n", trim: true)
    shown = lines |> Enum.take(4) |> Enum.map(&truncate(&1, 110))
    more = length(lines) - 4
    if more > 0, do: shown ++ ["… #{more} more lines"], else: shown
  end

  defp truncate(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max - 1) <> "…", else: text
  end

  defp read_line, do: IO.gets("") |> to_string() |> String.trim()

  defp respond(st, v, body) do
    Req.post!("#{st.base}/agui/v1/sessions/#{v["conversationId"]}/input", json: body, headers: st.headers)
  end
end

AGUIClient.main(System.argv())
