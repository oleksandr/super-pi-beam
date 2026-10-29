defmodule SuperPi.AI.StreamNormalizerDefectsTest do
  @moduledoc """
  Regression tests that reproduce `SuperPi.AI.StreamNormalizer` defects found in the
  code review. Every test is expected to FAIL on the current code and pass once the
  matching finding is fixed.

  Run only these:  mix test --only known_bug
  Skip these:      mix test --exclude known_bug
  """
  use ExUnit.Case, async: true

  alias SuperPi.AI.StreamNormalizer

  @moduletag :known_bug

  defp run(provider, chunks) when is_list(chunks) do
    {events, st} =
      Enum.reduce(chunks, {[], StreamNormalizer.new(provider, "m")}, fn chunk, {acc, st} ->
        {evs, st2} = StreamNormalizer.feed_chunk(st, chunk)
        {acc ++ evs, st2}
      end)

    {flush, _} = StreamNormalizer.flush(st)
    events ++ flush
  end

  defp done(events), do: Enum.find_value(events, fn {:done, d} -> d; _ -> nil end)

  defp sse(map), do: "data: " <> Jason.encode!(map) <> "\n\n"

  defp gemini(parts, extra \\ %{}) do
    sse(Map.merge(%{"candidates" => [%{"content" => %{"parts" => parts}}]}, extra))
  end

  defp types(done), do: Enum.map(done.content, & &1["type"])

  # --- Finding 9: non-object JSON payloads ---

  describe "non-object JSON data lines (stream_normalizer.ex:187-193)" do
    for provider <- [:anthropic, :openai, :google],
        {label, payload} <- [array: "[1,2]", string: ~s("hello"), number: "42", null: "null", bool: "true"] do
      test "#{provider}: #{label} payload does not raise" do
        result =
          try do
            {:ok, run(unquote(provider), ["data: #{unquote(payload)}\n\n"])}
          rescue
            e -> {:raised, e}
          end

        assert {:ok, events} = result, "feed_chunk raised: #{inspect(result)}"
        assert is_list(events)
      end
    end
  end

  # --- Finding 10: Google block ordering and chunk-split invariance ---

  describe "Google block order (stream_normalizer.ex:283-304,337-344)" do
    test "final content keeps arrival order thinking, text, tool_call" do
      stream =
        gemini(
          [
            %{"thought" => true, "text" => "T"},
            %{"text" => "X"},
            %{"functionCall" => %{"name" => "read", "args" => %{"path" => "a"}}}
          ],
          %{}
        )

      d = run(:google, [stream, "data: [DONE]\n\n"]) |> done()
      assert types(d) == ["thinking", "text", "tool_call"], "got #{inspect(types(d))}"
    end

    test "a tool call that arrives before later text keeps its position" do
      stream =
        gemini([
          %{"text" => "before"},
          %{"functionCall" => %{"name" => "read", "args" => %{}}},
          %{"text" => "after"}
        ])

      d = run(:google, [stream, "data: [DONE]\n\n"]) |> done()
      assert types(d) == ["text", "tool_call", "text"], "got #{inspect(types(d))}"
    end

    test "splitting the same parts across SSE events does not change the final content" do
      parts = [
        %{"text" => "a"},
        %{"thought" => true, "text" => "T"},
        %{"text" => "b"},
        %{"functionCall" => %{"name" => "read", "args" => %{"path" => "a"}}}
      ]

      single = run(:google, [gemini(parts), "data: [DONE]\n\n"]) |> done()
      split = run(:google, Enum.map(parts, &gemini([&1])) ++ ["data: [DONE]\n\n"]) |> done()

      assert split.content == single.content
    end

    test "interleaved thought/text across events is not merged out of order" do
      chunks = [
        gemini([%{"thought" => true, "text" => "t1"}]),
        gemini([%{"text" => "a"}]),
        gemini([%{"thought" => true, "text" => "t2"}]),
        gemini([%{"text" => "b"}]),
        "data: [DONE]\n\n"
      ]

      d = run(:google, chunks) |> done()
      assert types(d) == ["thinking", "text", "thinking", "text"], "got #{inspect(d.content)}"
    end
  end

  # --- Finding 11: OpenAI shapes ---

  describe "OpenAI Responses API and null fields (stream_normalizer.ex:247-262,439)" do
    test "response.completed ends the stream with a :done event and usage" do
      chunks = [
        sse(%{"type" => "response.output_text.delta", "content_index" => 0, "delta" => "hi"}),
        sse(%{"type" => "response.completed", "response" => %{"usage" => %{"input_tokens" => 5, "output_tokens" => 7}}})
      ]

      d = run(:openai, chunks) |> done()
      assert d != nil, "no :done emitted for response.completed (stream has no [DONE] marker)"
      assert d.usage["output_tokens"] == 7
    end

    test "Responses API function calls produce toolcall_delta events and a tool_call block" do
      chunks = [
        sse(%{"type" => "response.output_item.added", "output_index" => 0, "item" => %{"type" => "function_call", "call_id" => "call_1", "name" => "read"}}),
        sse(%{"type" => "response.function_call_arguments.delta", "output_index" => 0, "delta" => ~s({"path":"a"})}),
        sse(%{"type" => "response.completed", "response" => %{}})
      ]

      events = run(:openai, chunks)
      assert Enum.any?(events, &match?({:toolcall_delta, _}, &1)), "tool call events dropped: #{inspect(events)}"
    end

    test "a tool_calls delta with \"arguments\": null does not raise" do
      chunk = sse(%{"choices" => [%{"delta" => %{"tool_calls" => [%{"index" => 0, "id" => "c1", "function" => %{"name" => "read", "arguments" => nil}}]}}]})
      assert {:ok, _} = safe(fn -> run(:openai, [chunk]) end)
    end

    test "a response.output_text.delta with \"delta\": null does not raise" do
      chunk = sse(%{"type" => "response.output_text.delta", "content_index" => 0, "delta" => nil})
      assert {:ok, _} = safe(fn -> run(:openai, [chunk]) end)
    end

    test "a chat-completions choice with \"delta\": null does not raise" do
      chunk = sse(%{"choices" => [%{"delta" => nil, "finish_reason" => "stop"}]})
      assert {:ok, _} = safe(fn -> run(:openai, [chunk]) end)
    end
  end

  defp safe(fun) do
    {:ok, fun.()}
  rescue
    e -> {:raised, e}
  end

  # --- Finding 12: Anthropic block types and SSE framing ---

  describe "unknown Anthropic blocks (stream_normalizer.ex:362-364)" do
    test "redacted_thinking blocks are preserved, not turned into empty text" do
      chunks = [
        sse(%{"type" => "content_block_start", "index" => 0, "content_block" => %{"type" => "redacted_thinking", "data" => "opaque"}}),
        sse(%{"type" => "message_stop"})
      ]

      d = run(:anthropic, chunks) |> done()
      assert Enum.any?(d.content, &(&1["type"] == "redacted_thinking" and &1["data"] == "opaque")), "got #{inspect(d.content)}"
    end

    test "server_tool_use blocks do not become empty text blocks" do
      chunks = [
        sse(%{"type" => "content_block_start", "index" => 0, "content_block" => %{"type" => "server_tool_use", "id" => "srv_1", "name" => "web_search"}}),
        sse(%{"type" => "message_stop"})
      ]

      d = run(:anthropic, chunks) |> done()
      refute %{"type" => "text", "text" => ""} in d.content, "got #{inspect(d.content)}"
    end
  end

  describe "SSE framing (stream_normalizer.ex:59,168-175)" do
    test "bare CR line endings are honoured" do
      payload = Jason.encode!(%{"type" => "content_block_delta", "index" => 0, "delta" => %{"type" => "text_delta", "text" => "hi"}})
      events = run(:anthropic, ["data: " <> payload <> "\r\r" <> "data: " <> payload <> "\r\r"])
      deltas = Enum.filter(events, &match?({:text_delta, %{delta: "hi"}}, &1))
      assert length(deltas) == 2, "got #{inspect(events)}"
    end

    test "a data event split over several data: lines is joined" do
      events =
        run(:anthropic, [
          ~s(data: {"type":"content_block_delta","index":0,\n),
          ~s(data: "delta":{"type":"text_delta","text":"hi"}}\n\n)
        ])

      refute Enum.any?(events, &match?({:error, _}, &1)), "multi-line data produced #{inspect(events)}"
      assert Enum.any?(events, &match?({:text_delta, %{delta: "hi"}}, &1))
    end
  end

  # --- Finding 13: repair_truncated_json ---

  describe "partial tool arguments (stream_normalizer.ex:515-570)" do
    test "a 100KB argument fed in 50-byte deltas is processed in linear-ish time" do
      value = String.duplicate("a", 100_000)
      json = Jason.encode!(%{"content" => value})

      deltas = for <<piece::binary-size(50) <- binary_part(json, 0, div(byte_size(json), 50) * 50)>>, do: piece
      rest = binary_part(json, div(byte_size(json), 50) * 50, rem(byte_size(json), 50))

      start_ev =
        sse(%{"type" => "content_block_start", "index" => 0, "content_block" => %{"type" => "tool_use", "id" => "t", "name" => "write"}})

      chunks =
        [start_ev] ++
          Enum.map(deltas ++ [rest], fn d ->
            sse(%{"type" => "content_block_delta", "index" => 0, "delta" => %{"type" => "input_json_delta", "partial_json" => d}})
          end)

      {micros, _} = :timer.tc(fn -> run(:anthropic, chunks) end)
      assert micros < 1_000_000, "took #{div(micros, 1000)} ms for 2000 deltas (quadratic repair)"
    end

    test "a truncated \\u escape keeps the already-streamed arguments" do
      assert %{"a" => "hello" <> _} = StreamNormalizer.parse_partial_json(~S({"a":"hello \u00))
    end
  end
end
