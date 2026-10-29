defmodule SuperPi.AI.StreamNormalizerTest do
  use SuperPi.DataCase, async: false
  use ExUnitProperties

  alias SuperPi.AI.StreamNormalizer
  alias SuperPi.AI.VirtualModel
  alias SuperPi.Durable.Storage

  describe "Property-Based Tests: SSE Stream Chunk-Boundary Invariance & Cross-Provider Sanitization (REQ-PBT-04)" do
    property "arbitrary byte-chunk splitting of an Anthropic SSE stream yields identical :done content and tool arguments" do
      check all(
              text_part <- string(:alphanumeric, min_length: 3, max_length: 40),
              thinking_part <- string(:alphanumeric, min_length: 3, max_length: 40),
              sig_part <- string(:alphanumeric, min_length: 8, max_length: 24),
              tool_name <- member_of(["read", "write", "edit", "bash", "grep"]),
              file_path <- string(:alphanumeric, min_length: 4, max_length: 20),
              line_limit <- integer(1..500),
              chunk_sizes <- list_of(integer(1..37), min_length: 5, max_length: 40),
              max_runs: 50
            ) do
        tool_args = %{"path" => "/tmp/#{file_path}.ex", "limit" => line_limit}
        tool_json = Jason.encode!(tool_args)

        # Split tool_json into 3 pieces to simulate partial JSON deltas inside SSE events
        mid1 = div(byte_size(tool_json), 3)
        mid2 = div(byte_size(tool_json) * 2, 3)
        json_p1 = binary_part(tool_json, 0, mid1)
        json_p2 = binary_part(tool_json, mid1, mid2 - mid1)
        json_p3 = binary_part(tool_json, mid2, byte_size(tool_json) - mid2)

        sse_stream =
          [
            ~s(event: message_start\ndata: {"type":"message_start","message":{"usage":{"input_tokens":120,"cache_read_input_tokens":80}}}\n\n),
            ~s(event: content_block_start\ndata: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}\n\n),
            ~s(event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":#{Jason.encode!(thinking_part)}}}\n\n),
            ~s(event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":#{Jason.encode!(sig_part)}}}\n\n),
            ~s(event: content_block_start\ndata: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}\n\n),
            ~s(event: content_block_delta\ndata: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":#{Jason.encode!(text_part)}}}\n\n),
            ~s(event: content_block_start\ndata: {"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_01","name":#{Jason.encode!(tool_name)}}}\n\n),
            ~s(event: content_block_delta\ndata: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":#{Jason.encode!(json_p1)}}}\n\n),
            ~s(event: content_block_delta\ndata: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":#{Jason.encode!(json_p2)}}}\n\n),
            ~s(event: content_block_delta\ndata: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":#{Jason.encode!(json_p3)}}}\n\n),
            ~s(event: message_delta\ndata: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":45}}\n\n),
            ~s(event: message_stop\ndata: {"type":"message_stop"}\n\n)
          ]
          |> Enum.join("")

        # Reference single-shot feed
        {ref_events, ref_state} = StreamNormalizer.feed_chunk(StreamNormalizer.new(:anthropic, "claude-sonnet-4-5"), sse_stream)
        {ref_flush, _} = StreamNormalizer.flush(ref_state)
        all_ref = ref_events ++ ref_flush

        # Arbitrary byte-chunked feed
        chunks = split_binary_by_sizes(sse_stream, chunk_sizes)

        {chunked_events, final_state} =
          Enum.reduce(chunks, {[], StreamNormalizer.new(:anthropic, "claude-sonnet-4-5")}, fn ch, {ev_acc, st} ->
            {evs, st2} = StreamNormalizer.feed_chunk(st, ch)
            {ev_acc ++ evs, st2}
          end)

        {flush_events, _} = StreamNormalizer.flush(final_state)
        all_chunked = chunked_events ++ flush_events

        assert all_chunked == all_ref

        {:done, done_payload} = List.last(all_chunked)
        assert done_payload.stop_reason == "tool_use"
        assert done_payload.usage == %{"input_tokens" => 120, "output_tokens" => 45, "cache_read_tokens" => 80}

        [thinking_block, text_block, tool_block] = done_payload.content
        assert thinking_block == %{"type" => "thinking", "thinking" => thinking_part, "signature" => sig_part}
        assert text_block == %{"type" => "text", "text" => text_part}
        assert tool_block == %{"type" => "tool_call", "id" => "toolu_01", "name" => tool_name, "arguments" => tool_args}
      end
    end

    property "parse_partial_json never raises on arbitrary prefixes of valid JSON objects and returns a map" do
      check all(
              key1 <- string(:alphanumeric, min_length: 1, max_length: 12),
              val1 <- string(:alphanumeric, min_length: 1, max_length: 25),
              key2 <- string(:alphanumeric, min_length: 1, max_length: 12),
              val2 <- integer(1..10_000),
              cut_pos <- integer(1..100),
              max_runs: 50
            ) do
        full_json = Jason.encode!(%{key1 => val1, key2 => val2})
        prefix_len = min(cut_pos, byte_size(full_json))
        prefix = binary_part(full_json, 0, prefix_len)

        parsed = StreamNormalizer.parse_partial_json(prefix)
        assert is_map(parsed)

        # Full JSON always decodes to exact map
        assert StreamNormalizer.parse_partial_json(full_json) == %{key1 => val1, key2 => val2}
      end
    end

    property "cross-provider sanitization strips cryptographic thinkingSignature on provider switch and preserves it on same origin" do
      check all(
              origin_provider <- member_of([:anthropic, :openai, :google]),
              target_provider <- member_of([:anthropic, :openai, :google]),
              thought_text <- string(:alphanumeric, min_length: 4, max_length: 30),
              signature <- string(:alphanumeric, min_length: 10, max_length: 30),
              reply_text <- string(:alphanumeric, min_length: 4, max_length: 30),
              max_runs: 50
            ) do
        origin_model = "model-#{origin_provider}"
        target_model = if origin_provider == target_provider, do: origin_model, else: "model-#{target_provider}"

        messages = [
          %{
            "role" => "assistant",
            "provider" => to_string(origin_provider),
            "model" => origin_model,
            "thinkingSignature" => signature,
            "content" => [
              %{"type" => "thinking", "thinking" => thought_text, "signature" => signature, "thinkingSignature" => signature},
              %{"type" => "redacted_thinking", "data" => "encrypted_blob"},
              %{"type" => "text", "text" => reply_text}
            ]
          }
        ]

        [sanitized] = StreamNormalizer.sanitize_messages_for_target(messages, target_provider, target_model)

        if origin_provider == target_provider do
          assert Enum.any?(sanitized["content"], &(&1["type"] == "thinking" and &1["signature"] == signature))
          assert Enum.any?(sanitized["content"], &(&1["type"] == "redacted_thinking"))
        else
          refute Map.has_key?(sanitized, "thinkingSignature")
          refute Enum.any?(sanitized["content"], &(&1["type"] == "redacted_thinking"))

          Enum.each(sanitized["content"], fn block ->
            refute Map.has_key?(block, "signature")
            refute Map.has_key?(block, "thinkingSignature")
          end)
        end
      end
    end

    test "VirtualModel resolves virtual aliases and maintains UUIDv7 session affinity across turns and forks" do
      resolved = VirtualModel.resolve("coding")
      assert resolved.provider == :anthropic
      assert resolved.model == "claude-sonnet-4-5"
      assert resolved.thinking_budget == 8_192

      fallback = VirtualModel.resolve("coding", fallback: true)
      assert fallback.provider == :openai
      assert fallback.model == "gpt-5"

      conv = Storage.create_conversation!()
      p1 = VirtualModel.ensure_provider_session!(conv.id, :anthropic, "claude-sonnet-4-5")
      p2 = VirtualModel.ensure_provider_session!(conv.id, :anthropic, "claude-sonnet-4-5")
      assert p1["sessionId"] == p2["sessionId"]

      e1 = Storage.append_entry!(conv.id, "pi.message", %{"role" => "user", "content" => "hi"})
      fork_conv = Storage.fork_conversation!(conv.id, e1.id)
      fork_p = VirtualModel.ensure_provider_session!(fork_conv.id, :anthropic, "claude-sonnet-4-5")
      assert fork_p["sessionId"] != p1["sessionId"]
    end

    test "Google Gemini SSE stream normalizer extracts usageMetadata and populates usage tokens in :done payload" do
      sse_stream =
        ~s(data: {"candidates":[{"content":{"parts":[{"text":"Hello world"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":1250,"candidatesTokenCount":45,"totalTokenCount":1295}}\n\n)

      normalizer = StreamNormalizer.new(:google, "gemini-3-flash-preview")
      {events, st} = StreamNormalizer.feed_chunk(normalizer, sse_stream)
      {flush_events, _} = StreamNormalizer.flush(st)
      all_events = events ++ flush_events

      done_payload =
        Enum.find_value(all_events, fn
          {:done, payload} -> payload
          _ -> nil
        end)

      assert done_payload != nil
      assert done_payload.usage["input_tokens"] == 1250
      assert done_payload.usage["output_tokens"] == 45
    end

    test "OpenAI SSE stream normalizer extracts usage and populates usage tokens in :done payload" do
      sse_stream =
        [
          ~s(data: {"choices":[{"index":0,"delta":{"content":"Hi"}}]}\n\n),
          ~s(data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":520,"completion_tokens":12,"total_tokens":532}}\n\n),
          ~s(data: [DONE]\n\n)
        ]
        |> Enum.join("")

      normalizer = StreamNormalizer.new(:openai, "gpt-4o")
      {events, st} = StreamNormalizer.feed_chunk(normalizer, sse_stream)
      {flush_events, _} = StreamNormalizer.flush(st)
      all_events = events ++ flush_events

      done_payload =
        Enum.find_value(all_events, fn
          {:done, payload} -> payload
          _ -> nil
        end)

      assert done_payload != nil
      assert done_payload.usage["input_tokens"] == 520
      assert done_payload.usage["output_tokens"] == 12
    end
  end

  defp split_binary_by_sizes(<<>>, _sizes), do: []

  defp split_binary_by_sizes(bin, [sz | rest]) do
    take = min(sz, byte_size(bin))
    <<chunk::binary-size(^take), rem_bin::binary>> = bin
    [chunk | split_binary_by_sizes(rem_bin, rest ++ [sz])]
  end
end
