defmodule SuperPi.AI.StreamNormalizer do
  @moduledoc """
  Unified multi-provider LLM SSE stream normalizer and cross-provider message sanitizer (`REQ-PBT-04`).

  Normalizes raw Server-Sent Event (SSE) byte streams from:
  - `:anthropic` (`anthropic-messages`)
  - `:openai` (`openai-responses` / `openai-completions`)
  - `:google` (`google-generative-ai`)

  into a canonical sequence of events:
  - `{:start, %{model: String.t(), provider: atom()}}`
  - `{:text_delta, %{index: non_neg_integer(), delta: String.t()}}`
  - `{:thinking_delta, %{index: non_neg_integer(), delta: String.t(), signature: String.t() | nil}}`
  - `{:toolcall_delta, %{index: non_neg_integer(), id: String.t(), name: String.t(), raw_json_delta: String.t(), partial_args: map()}}`
  - `{:done, %{stop_reason: String.t(), content: list(map()), usage: map()}}`
  - `{:error, %{reason: term()}}`

  Guarantees chunk-boundary invariance (`REQ-PBT-04`): arbitrary byte-level chunk splitting of an
  SSE stream produces the exact same final `:done` message and accumulated tool-call arguments.
  """

  defstruct provider: :anthropic,
            model: "claude-sonnet-4-5",
            buffer: "",
            started?: false,
            blocks: %{},
            usage: %{"input_tokens" => 0, "output_tokens" => 0, "cache_read_tokens" => 0},
            stop_reason: "end_turn",
            data_lines: [],
            last_was_cr?: false,
            block_counter: 0,
            active_block_idx: nil,
            done?: false

  @type t :: %__MODULE__{
          provider: :anthropic | :openai | :google,
          model: String.t(),
          buffer: String.t(),
          started?: boolean(),
          blocks: map(),
          usage: map(),
          stop_reason: String.t(),
          data_lines: list(String.t()),
          last_was_cr?: boolean(),
          block_counter: non_neg_integer(),
          active_block_idx: non_neg_integer() | nil,
          done?: boolean()
        }

  @doc """
  Initializes a new stream normalizer state for `provider` and `model`.
  """
  def new(provider \\ :anthropic, model \\ "claude-sonnet-4-5")
      when provider in [:anthropic, :openai, :google] and is_binary(model) do
    %__MODULE__{provider: provider, model: model}
  end

  @doc """
  Feeds an arbitrary binary chunk into the SSE normalizer and returns `{normalized_events, next_state}`.
  Handles arbitrary mid-line and mid-JSON chunk boundaries without losing state.
  """
  @spec feed_chunk(t(), binary()) :: {list(tuple()), t()}
  def feed_chunk(%__MODULE__{} = state, chunk) when is_binary(chunk) do
    # If the previous chunk ended with \r, and this chunk starts with \n, drop that \n
    chunk =
      if state.last_was_cr? and String.starts_with?(chunk, "\n") do
        binary_part(chunk, 1, byte_size(chunk) - 1)
      else
        chunk
      end

    combined = state.buffer <> chunk
    {lines, remaining_buffer, last_was_cr?} = extract_lines(combined)

    state = %__MODULE__{state | buffer: remaining_buffer, last_was_cr?: last_was_cr?}

    Enum.reduce(lines, {[], state}, fn line, {acc_events, st} ->
      {new_events, st2} = process_line(st, line)
      {acc_events ++ new_events, st2}
    end)
  end

  @doc """
  Flushes any remaining complete SSE data in the buffer and returns `{events, final_state}`.
  """
  @spec flush(t()) :: {list(tuple()), t()}
  def flush(%__MODULE__{buffer: "", data_lines: []} = state), do: {[], state}

  def flush(%__MODULE__{} = state) do
    {lines, _rem, _cr} = extract_lines(state.buffer <> "\n")
    state = %__MODULE__{state | buffer: "", last_was_cr?: false}

    {line_events, state} =
      Enum.reduce(lines, {[], state}, fn line, {acc_events, st} ->
        {new_events, st2} = process_line(st, line)
        {acc_events ++ new_events, st2}
      end)

    {dispatch_events, state} = dispatch_buffered_event(state)
    {line_events ++ dispatch_events, state}
  end

  @doc """
  Best-effort incremental JSON object parser for streaming `toolcall_delta` arguments.
  Automatically closes unclosed strings, arrays, and objects so callers can inspect `partial_args`
  before the tool call block finishes streaming.
  """
  @spec parse_partial_json(String.t()) :: map()
  def parse_partial_json(""), do: %{}

  def parse_partial_json(raw) when is_binary(raw) do
    trimmed = String.trim(raw)

    case Jason.decode(trimmed) do
      {:ok, map} when is_map(map) ->
        map

      _ ->
        repaired = repair_truncated_json(trimmed)

        case Jason.decode(repaired) do
          {:ok, map} when is_map(map) -> map
          _ -> %{}
        end
    end
  end

  @doc """
  Sanitizes conversation history messages when switching across LLM providers or models (`spec.md` §5):
  - Strips provider-proprietary `thinkingSignature` / `redacted_thinking` fields or downgrades
    unrecognized thinking blocks to plain text / omitted metadata when moving between providers
    (e.g. `:anthropic` -> `:openai` or `:google`).
  - Preserves `thinkingSignature` intact when the target `(provider, model)` matches the block's origin.
  """
  @spec sanitize_messages_for_target(list(map()), atom(), String.t()) :: list(map())
  def sanitize_messages_for_target(messages, target_provider, target_model)
      when is_list(messages) and is_atom(target_provider) and is_binary(target_model) do
    Enum.map(messages, fn msg ->
      msg_provider = Map.get(msg, "provider") || Map.get(msg, :provider)
      msg_model = Map.get(msg, "model") || Map.get(msg, :model)

      same_origin? =
        to_string(msg_provider) == to_string(target_provider) and msg_model == target_model

      case Map.get(msg, "content") do
        blocks when is_list(blocks) ->
          sanitized_blocks =
            blocks
            |> Enum.map(&sanitize_block(&1, same_origin?, target_provider))
            |> Enum.reject(&is_nil/1)

          msg
          |> Map.put("content", sanitized_blocks)
          |> Map.delete("thinkingSignature")

        _ ->
          if same_origin? do
            msg
          else
            Map.delete(msg, "thinkingSignature")
          end
      end
    end)
  end

  # --- Private Implementation ---

  defp sanitize_block(%{"type" => "thinking"} = block, true = _same_origin?, _target_provider) do
    block
  end

  defp sanitize_block(%{"type" => "thinking"} = block, false = _same_origin?, target_provider) do
    thinking_text = Map.get(block, "thinking", "")

    case target_provider do
      :anthropic ->
        # Anthropic rejects foreign or unsigned thinking blocks; convert to plain text context
        if String.trim(thinking_text) == "" do
          nil
        else
          %{"type" => "text", "text" => "<thinking>\n#{thinking_text}\n</thinking>"}
        end

      _ ->
        # Strip proprietary cryptographic signature for OpenAI/Google
        block
        |> Map.delete("signature")
        |> Map.delete("thinkingSignature")
    end
  end

  defp sanitize_block(%{"type" => "redacted_thinking"} = block, true, _target_provider), do: block
  defp sanitize_block(%{"type" => "redacted_thinking"}, false, _target_provider), do: nil
  defp sanitize_block(other, _same_origin?, _target_provider), do: other

  defp extract_lines(binary) do
    do_extract_lines(binary, 0, 0, [], false)
  end

  defp do_extract_lines(binary, pos, line_start, lines_acc, last_was_cr?) do
    case :binary.match(binary, ["\r", "\n"], [{:scope, {pos, byte_size(binary) - pos}}]) do
      :nomatch ->
        remaining = binary_part(binary, line_start, byte_size(binary) - line_start)
        {Enum.reverse(lines_acc), remaining, last_was_cr?}

      {match_pos, 1} ->
        char = :binary.at(binary, match_pos)

        if char == ?\n do
          line = binary_part(binary, line_start, match_pos - line_start)
          do_extract_lines(binary, match_pos + 1, match_pos + 1, [line | lines_acc], false)
        else
          # char == ?\r
          line = binary_part(binary, line_start, match_pos - line_start)

          if match_pos + 1 < byte_size(binary) do
            if :binary.at(binary, match_pos + 1) == ?\n do
              # \r\n
              do_extract_lines(binary, match_pos + 2, match_pos + 2, [line | lines_acc], false)
            else
              # bare \r
              do_extract_lines(binary, match_pos + 1, match_pos + 1, [line | lines_acc], false)
            end
          else
            # \r at the very end of binary
            {Enum.reverse([line | lines_acc]), "", true}
          end
        end
    end
  end

  defp process_line(state, "") do
    dispatch_buffered_event(state)
  end

  defp process_line(state, ":" <> _) do
    {[], state}
  end

  defp process_line(state, "event:" <> _) do
    {[], state}
  end

  defp process_line(%__MODULE__{} = state, "data:" <> raw_payload) do
    payload =
      case raw_payload do
        " " <> rest -> rest
        other -> other
      end

    {[], %__MODULE__{state | data_lines: [payload | state.data_lines]}}
  end

  defp process_line(state, _other) do
    {[], state}
  end

  defp dispatch_buffered_event(%__MODULE__{data_lines: []} = state) do
    {[], state}
  end

  defp dispatch_buffered_event(%__MODULE__{data_lines: lines} = state) do
    payload = lines |> Enum.reverse() |> Enum.join("\n")
    state = %__MODULE__{state | data_lines: []}

    if payload == "[DONE]" do
      finalize_stream(state)
    else
      case Jason.decode(payload) do
        {:ok, decoded} when is_map(decoded) ->
          normalize_provider_event(state, decoded)

        {:ok, _non_map} ->
          {[], state}

        {:error, reason} ->
          {[{:error, %{reason: {:invalid_sse_json, reason, payload}}}], state}
      end
    end
  end

  defp normalize_provider_event(%__MODULE__{provider: :anthropic} = state, event) do
    {start_events, state} = ensure_started(state)

    case Map.get(event, "type") do
      "message_start" ->
        usage = get_in(event, ["message", "usage"]) || %{}
        next_usage = merge_usage(state.usage, usage)
        {start_events, %__MODULE__{state | usage: next_usage}}

      "content_block_start" ->
        idx = Map.get(event, "index", 0)
        cb = Map.get(event, "content_block", %{})
        block_state = init_block_from_anthropic(cb)
        {start_events, %__MODULE__{state | blocks: Map.put(state.blocks, idx, block_state)}}

      "content_block_delta" ->
        idx = Map.get(event, "index", 0)
        delta = Map.get(event, "delta", %{})
        apply_anthropic_delta(state, start_events, idx, delta)

      "message_delta" ->
        stop_reason = get_in(event, ["delta", "stop_reason"]) || state.stop_reason
        usage = Map.get(event, "usage", %{})

        {start_events,
         %__MODULE__{state | stop_reason: stop_reason, usage: merge_usage(state.usage, usage)}}

      "message_stop" ->
        {done_events, final_state} = finalize_stream(state)
        {start_events ++ done_events, final_state}

      "error" ->
        err = Map.get(event, "error", %{"message" => "unknown_error"})
        {start_events ++ [{:error, %{reason: err, retryable: retryable_error?(err)}}], state}

      _ ->
        {start_events, state}
    end
  end

  defp normalize_provider_event(%__MODULE__{provider: :openai} = state, event) do
    {start_events, state} = ensure_started(state)

    usage = Map.get(event, "usage")

    state =
      if is_map(usage),
        do: %__MODULE__{state | usage: merge_usage(state.usage, usage)},
        else: state

    # Support both OpenAI Chat Completions deltas and Responses API events
    cond do
      # An error sent inside a 200 stream.
      is_map(Map.get(event, "error")) ->
        err = event["error"]
        {start_events ++ [{:error, %{reason: err, retryable: retryable_error?(err)}}], state}

      is_list(Map.get(event, "choices")) ->
        choice = List.first(event["choices"]) || %{}
        delta = Map.get(choice, "delta") || %{}
        finish = Map.get(choice, "finish_reason")
        {delta_events, %__MODULE__{} = st} = apply_openai_choice_delta(state, delta)
        st = if finish, do: %__MODULE__{st | stop_reason: finish}, else: st
        {start_events ++ delta_events, st}

      Map.get(event, "type") == "response.completed" ->
        resp_usage = get_in(event, ["response", "usage"])

        st =
          if is_map(resp_usage),
            do: %__MODULE__{state | usage: merge_usage(state.usage, resp_usage)},
            else: state

        {done_events, final_st} = finalize_stream(st)
        {start_events ++ done_events, final_st}

      Map.get(event, "type") == "response.output_text.delta" ->
        idx = Map.get(event, "content_index", 0)
        text = Map.get(event, "delta") || ""
        block = Map.get(state.blocks, idx, %{"type" => "text", "text" => ""})
        updated = Map.put(block, "text", (block["text"] || "") <> text)
        st = %__MODULE__{state | blocks: Map.put(state.blocks, idx, updated)}
        {start_events ++ [{:text_delta, %{index: idx, delta: text}}], st}

      Map.get(event, "type") == "response.output_item.added" ->
        item = Map.get(event, "item", %{})
        output_idx = Map.get(event, "output_index", 0)

        case Map.get(item, "type") do
          "function_call" ->
            id = Map.get(item, "call_id") || "call_#{output_idx}"
            name = Map.get(item, "name", "")

            block = %{
              "type" => "tool_call",
              "id" => id,
              "name" => name,
              "raw_json" => "",
              "arguments" => %{}
            }

            {start_events, %__MODULE__{state | blocks: Map.put(state.blocks, output_idx, block)}}

          _ ->
            {start_events, state}
        end

      Map.get(event, "type") == "response.function_call_arguments.delta" ->
        output_idx = Map.get(event, "output_index", 0)
        delta = Map.get(event, "delta") || ""

        block =
          Map.get(state.blocks, output_idx, %{
            "type" => "tool_call",
            "id" => "call_#{output_idx}",
            "name" => "",
            "raw_json" => "",
            "arguments" => %{}
          })

        new_raw = (block["raw_json"] || "") <> delta
        partial = parse_partial_json(new_raw)
        updated = Map.merge(block, %{"raw_json" => new_raw, "arguments" => partial})

        ev =
          {:toolcall_delta,
           %{
             index: output_idx,
             id: updated["id"],
             name: updated["name"],
             raw_json_delta: delta,
             partial_args: partial
           }}

        {start_events ++ [ev],
         %__MODULE__{state | blocks: Map.put(state.blocks, output_idx, updated)}}

      true ->
        {start_events, state}
    end
  end

  defp normalize_provider_event(%__MODULE__{provider: :google} = state, event) do
    {start_events, state} = ensure_started(state)

    cond do
      is_map(Map.get(event, "error")) ->
        err = Map.get(event, "error")
        {start_events ++ [{:error, %{reason: err}}], state}

      get_in(event, ["promptFeedback", "blockReason"]) != nil ->
        block_reason = get_in(event, ["promptFeedback", "blockReason"])
        {start_events ++ [{:error, %{reason: {:prompt_blocked, block_reason}}}], state}

      true ->
        usage = Map.get(event, "usageMetadata")

        state =
          if is_map(usage),
            do: %__MODULE__{state | usage: merge_usage(state.usage, usage)},
            else: state

        candidates = Map.get(event, "candidates", [])

        case List.first(candidates) do
          nil ->
            {start_events, state}

          cand ->
            parts = get_in(cand, ["content", "parts"]) || []

            {part_events, %__MODULE__{} = st} =
              Enum.reduce(parts, {[], state}, fn part, {ev_acc, %__MODULE__{} = s_acc} ->
                cond do
                  Map.get(part, "thought") == true ->
                    text = Map.get(part, "text", "")
                    sig = Map.get(part, "thoughtSignature")

                    if s_acc.active_block_idx != nil and
                         get_in(s_acc.blocks, [s_acc.active_block_idx, "type"]) == "thinking" do
                      idx = s_acc.active_block_idx
                      block = s_acc.blocks[idx]
                      prev_thinking = block["thinking"] || ""

                      updated = %{
                        block
                        | "thinking" => prev_thinking <> text,
                          "signature" => sig || block["signature"]
                      }

                      s_next = %__MODULE__{s_acc | blocks: Map.put(s_acc.blocks, idx, updated)}

                      {ev_acc ++
                         [
                           {:thinking_delta,
                            %{index: idx, delta: text, signature: updated["signature"]}}
                         ], s_next}
                    else
                      idx = s_acc.block_counter
                      block = %{"type" => "thinking", "thinking" => text, "signature" => sig}

                      s_next = %__MODULE__{
                        s_acc
                        | blocks: Map.put(s_acc.blocks, idx, block),
                          block_counter: idx + 1,
                          active_block_idx: idx
                      }

                      {ev_acc ++ [{:thinking_delta, %{index: idx, delta: text, signature: sig}}],
                       s_next}
                    end

                  is_binary(Map.get(part, "text")) ->
                    text = part["text"]
                    sig = Map.get(part, "thoughtSignature")

                    if s_acc.active_block_idx != nil and
                         get_in(s_acc.blocks, [s_acc.active_block_idx, "type"]) == "text" do
                      idx = s_acc.active_block_idx
                      block = s_acc.blocks[idx]
                      prev_text = block["text"] || ""
                      updated = %{block | "text" => prev_text <> text}

                      updated =
                        if sig, do: Map.put(updated, "thoughtSignature", sig), else: updated

                      s_next = %__MODULE__{s_acc | blocks: Map.put(s_acc.blocks, idx, updated)}
                      {ev_acc ++ [{:text_delta, %{index: idx, delta: text}}], s_next}
                    else
                      idx = s_acc.block_counter
                      block = %{"type" => "text", "text" => text}
                      block = if sig, do: Map.put(block, "thoughtSignature", sig), else: block

                      s_next = %__MODULE__{
                        s_acc
                        | blocks: Map.put(s_acc.blocks, idx, block),
                          block_counter: idx + 1,
                          active_block_idx: idx
                      }

                      {ev_acc ++ [{:text_delta, %{index: idx, delta: text}}], s_next}
                    end

                  is_map(Map.get(part, "functionCall")) ->
                    fc = part["functionCall"]
                    name = Map.get(fc, "name", "tool")

                    tool_count =
                      Enum.count(s_acc.blocks, fn {_k, b} -> b["type"] == "tool_call" end) + 1

                    id = Map.get(fc, "id") || "fc_#{tool_count}"
                    args = Map.get(fc, "args", %{})
                    sig = Map.get(part, "thoughtSignature") || Map.get(fc, "thoughtSignature")
                    raw_json = Jason.encode!(args)

                    idx = s_acc.block_counter

                    block = %{
                      "type" => "tool_call",
                      "id" => id,
                      "name" => name,
                      "raw_json" => raw_json,
                      "arguments" => args
                    }

                    block = if sig, do: Map.put(block, "thoughtSignature", sig), else: block

                    s_next = %__MODULE__{
                      s_acc
                      | blocks: Map.put(s_acc.blocks, idx, block),
                        block_counter: idx + 1,
                        active_block_idx: idx
                    }

                    ev =
                      {:toolcall_delta,
                       %{
                         index: idx,
                         id: id,
                         name: name,
                         raw_json_delta: raw_json,
                         partial_args: args
                       }}

                    {ev_acc ++ [ev], s_next}

                  true ->
                    {ev_acc, s_acc}
                end
              end)

            finish = Map.get(cand, "finishReason")

            if finish in ["STOP", "MAX_TOKENS"] do
              {done_events, final_st} =
                finalize_stream(%__MODULE__{st | stop_reason: String.downcase(finish)})

              {start_events ++ part_events ++ done_events, final_st}
            else
              {start_events ++ part_events, st}
            end
        end
    end
  end

  defp ensure_started(%__MODULE__{started?: true} = state), do: {[], state}

  defp ensure_started(%__MODULE__{started?: false} = state) do
    {[{:start, %{provider: state.provider, model: state.model}}],
     %__MODULE__{state | started?: true}}
  end

  defp init_block_from_anthropic(%{"type" => "thinking"}) do
    %{"type" => "thinking", "thinking" => "", "signature" => nil}
  end

  defp init_block_from_anthropic(%{"type" => "tool_use", "id" => id, "name" => name}) do
    %{"type" => "tool_call", "id" => id, "name" => name, "raw_json" => "", "arguments" => %{}}
  end

  defp init_block_from_anthropic(%{"type" => "redacted_thinking", "data" => _data} = cb) do
    cb
  end

  defp init_block_from_anthropic(%{"type" => "text"}) do
    %{"type" => "text", "text" => ""}
  end

  defp init_block_from_anthropic(other) when is_map(other) do
    other
  end

  defp apply_anthropic_delta(%__MODULE__{} = state, start_events, idx, %{
         "type" => "text_delta",
         "text" => chunk
       }) do
    block = Map.get(state.blocks, idx, %{"type" => "text", "text" => ""})
    updated = Map.put(block, "text", block["text"] <> chunk)
    next_state = %__MODULE__{state | blocks: Map.put(state.blocks, idx, updated)}
    {start_events ++ [{:text_delta, %{index: idx, delta: chunk}}], next_state}
  end

  defp apply_anthropic_delta(%__MODULE__{} = state, start_events, idx, %{
         "type" => "thinking_delta",
         "thinking" => chunk
       }) do
    block =
      Map.get(state.blocks, idx, %{"type" => "thinking", "thinking" => "", "signature" => nil})

    updated = Map.put(block, "thinking", block["thinking"] <> chunk)
    next_state = %__MODULE__{state | blocks: Map.put(state.blocks, idx, updated)}

    {start_events ++
       [{:thinking_delta, %{index: idx, delta: chunk, signature: updated["signature"]}}],
     next_state}
  end

  defp apply_anthropic_delta(%__MODULE__{} = state, start_events, idx, %{
         "type" => "signature_delta",
         "signature" => sig_chunk
       }) do
    block =
      Map.get(state.blocks, idx, %{"type" => "thinking", "thinking" => "", "signature" => ""})

    prev_sig = block["signature"] || ""
    updated = Map.put(block, "signature", prev_sig <> sig_chunk)
    next_state = %__MODULE__{state | blocks: Map.put(state.blocks, idx, updated)}

    {start_events ++
       [{:thinking_delta, %{index: idx, delta: "", signature: updated["signature"]}}], next_state}
  end

  defp apply_anthropic_delta(%__MODULE__{} = state, start_events, idx, %{
         "type" => "input_json_delta",
         "partial_json" => json_chunk
       }) do
    block =
      Map.get(state.blocks, idx, %{
        "type" => "tool_call",
        "id" => "tool_#{idx}",
        "name" => "unknown",
        "raw_json" => "",
        "arguments" => %{}
      })

    new_raw = block["raw_json"] <> json_chunk
    partial = parse_partial_json(new_raw)

    updated = %{
      "type" => "tool_call",
      "id" => block["id"],
      "name" => block["name"],
      "raw_json" => new_raw,
      "arguments" => partial
    }

    next_state = %__MODULE__{state | blocks: Map.put(state.blocks, idx, updated)}

    ev =
      {:toolcall_delta,
       %{
         index: idx,
         id: updated["id"],
         name: updated["name"],
         raw_json_delta: json_chunk,
         partial_args: partial
       }}

    {start_events ++ [ev], next_state}
  end

  defp apply_anthropic_delta(%__MODULE__{} = state, start_events, _idx, _unknown_delta),
    do: {start_events, state}

  defp apply_openai_choice_delta(%__MODULE__{} = state, delta) do
    delta = delta || %{}

    {events, %__MODULE__{} = state} =
      case Map.get(delta, "content") do
        text when is_binary(text) and text != "" ->
          block = Map.get(state.blocks, 0, %{"type" => "text", "text" => ""})
          updated = Map.put(block, "text", (block["text"] || "") <> text)

          {[{:text_delta, %{index: 0, delta: text}}],
           %__MODULE__{state | blocks: Map.put(state.blocks, 0, updated)}}

        _ ->
          {[], state}
      end

    case Map.get(delta, "tool_calls") do
      tc_list when is_list(tc_list) ->
        Enum.reduce(tc_list, {events, state}, fn tc, {ev_acc, %__MODULE__{} = st_acc} ->
          idx = Map.get(tc, "index", 0) + 1

          existing =
            Map.get(st_acc.blocks, idx, %{
              "type" => "tool_call",
              "id" => "call_#{idx}",
              "name" => "",
              "raw_json" => "",
              "arguments" => %{}
            })

          id = Map.get(tc, "id") || existing["id"]
          fn_map = Map.get(tc, "function") || %{}
          name = Map.get(fn_map, "name") || existing["name"]
          arg_chunk = Map.get(fn_map, "arguments") || ""
          new_raw = existing["raw_json"] <> arg_chunk
          partial = parse_partial_json(new_raw)

          updated = %{
            "type" => "tool_call",
            "id" => id,
            "name" => name,
            "raw_json" => new_raw,
            "arguments" => partial
          }

          ev =
            {:toolcall_delta,
             %{index: idx, id: id, name: name, raw_json_delta: arg_chunk, partial_args: partial}}

          {ev_acc ++ [ev], %__MODULE__{st_acc | blocks: Map.put(st_acc.blocks, idx, updated)}}
        end)

      _ ->
        {events, state}
    end
  end

  defp finalize_stream(%__MODULE__{done?: true} = state), do: {[], state}

  defp finalize_stream(%__MODULE__{} = state) do
    ordered_content =
      state.blocks
      |> Enum.sort_by(fn {idx, _} -> idx end)
      |> Enum.map(fn {_idx, block} ->
        case block do
          %{"type" => "tool_call", "raw_json" => raw} = tc ->
            # Partial JSON is for UI deltas only. A tool runs only with arguments that parse.
            case strict_arguments(raw) do
              {:ok, args} -> tc |> Map.put("arguments", args) |> Map.delete("raw_json")
              :error -> {:invalid, tc["id"]}
            end

          other ->
            other
        end
      end)

    case for({:invalid, id} <- ordered_content, do: id) do
      [] ->
        finalize_valid(state, ordered_content)

      ids ->
        {[{:error, %{reason: {:invalid_tool_arguments, ids}, retryable: true}}],
         %__MODULE__{state | done?: true}}
    end
  end

  defp strict_arguments(raw) do
    if String.trim(raw) == "" do
      {:ok, %{}}
    else
      case Jason.decode(raw) do
        {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
        _ -> :error
      end
    end
  end

  # Overload, rate limit and internal errors pass; the request can be sent again.
  @retryable_errors ~w(overloaded_error rate_limit_error api_error server_error rate_limit_exceeded)

  defp retryable_error?(%{} = err),
    do: err["type"] in @retryable_errors or err["code"] in @retryable_errors

  defp retryable_error?(_), do: false

  defp finalize_valid(%__MODULE__{} = state, ordered_content) do
    done_event =
      {:done,
       %{
         stop_reason: state.stop_reason,
         content: ordered_content,
         usage: state.usage
       }}

    {[done_event], %__MODULE__{state | done?: true}}
  end

  defp merge_usage(prev, incoming) when is_map(incoming) do
    prev = prev || %{}

    %{
      "input_tokens" =>
        Map.get(incoming, "promptTokenCount") ||
          Map.get(incoming, "prompt_tokens") ||
          Map.get(incoming, "input_tokens") ||
          Map.get(prev, "input_tokens", 0),
      "output_tokens" =>
        Map.get(incoming, "candidatesTokenCount") ||
          Map.get(incoming, "completion_tokens") ||
          Map.get(incoming, "output_tokens") ||
          Map.get(prev, "output_tokens", 0),
      "cache_read_tokens" =>
        Map.get(incoming, "cachedContentTokenCount") ||
          Map.get(incoming, "cache_read_input_tokens") ||
          Map.get(incoming, "cache_read_tokens") ||
          Map.get(prev, "cache_read_tokens", 0)
    }
  end

  # Repairs truncated JSON strings/objects so partial tool arguments can be inspected live
  defp repair_truncated_json(str) do
    {in_string?, escaped?, stack} = fast_scan_json(str)

    base =
      cond do
        escaped? ->
          binary_part(str, 0, byte_size(str) - 1)

        in_string? ->
          strip_truncated_u(str)

        true ->
          str
      end

    base = if in_string?, do: base <> "\"", else: base
    base = strip_trailing_delimiters(base)

    closed =
      if ends_with_open_key?(base) do
        base <> ": null"
      else
        base
      end

    closed <> Enum.join(stack, "")
  end

  defp strip_truncated_u(str) do
    tail_len = min(byte_size(str), 6)
    prefix_len = byte_size(str) - tail_len
    tail = binary_part(str, prefix_len, tail_len)
    new_tail = Regex.replace(~r/\\u[0-9a-fA-F]{0,3}$/, tail, "")
    binary_part(str, 0, prefix_len) <> new_tail
  end

  defp strip_trailing_delimiters(str) do
    tail_len = min(byte_size(str), 16)
    prefix_len = byte_size(str) - tail_len
    tail = binary_part(str, prefix_len, tail_len)
    new_tail = Regex.replace(~r/[,:\s]+$/, tail, "")
    binary_part(str, 0, prefix_len) <> new_tail
  end

  defp ends_with_open_key?(str) do
    tail_len = min(byte_size(str), 64)
    prefix_len = byte_size(str) - tail_len
    tail = binary_part(str, prefix_len, tail_len)
    Regex.match?(~r/\{\s*"[^"]+"\s*$/, tail) or Regex.match?(~r/,\s*"[^"]+"\s*$/, tail)
  end

  defp fast_scan_json(binary) do
    do_fast_scan(binary, false, [])
  end

  defp do_fast_scan(binary, true = _in_str, stack) do
    case :binary.match(binary, ["\"", "\\"]) do
      :nomatch ->
        {true, false, stack}

      {pos, 1} ->
        char = :binary.at(binary, pos)
        rest = binary_part(binary, pos + 1, byte_size(binary) - pos - 1)

        if char == ?" do
          do_fast_scan(rest, false, stack)
        else
          case rest do
            <<>> ->
              {true, true, stack}

            <<_esc::8, after_esc::binary>> ->
              do_fast_scan(after_esc, true, stack)
          end
        end
    end
  end

  defp do_fast_scan(binary, false = _in_str, stack) do
    case :binary.match(binary, ["\"", "{", "}", "[", "]"]) do
      :nomatch ->
        {false, false, stack}

      {pos, 1} ->
        char = :binary.at(binary, pos)
        rest = binary_part(binary, pos + 1, byte_size(binary) - pos - 1)

        case char do
          ?" ->
            do_fast_scan(rest, true, stack)

          ?{ ->
            do_fast_scan(rest, false, ["}" | stack])

          ?[ ->
            do_fast_scan(rest, false, ["]" | stack])

          ?} ->
            new_stack =
              case stack do
                ["}" | rest_stack] -> rest_stack
                _ -> stack
              end

            do_fast_scan(rest, false, new_stack)

          ?] ->
            new_stack =
              case stack do
                ["]" | rest_stack] -> rest_stack
                _ -> stack
              end

            do_fast_scan(rest, false, new_stack)
        end
    end
  end
end
