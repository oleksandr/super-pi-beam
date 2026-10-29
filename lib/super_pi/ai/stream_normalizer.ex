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
            stop_reason: "end_turn"

  @type t :: %__MODULE__{
          provider: :anthropic | :openai | :google,
          model: String.t(),
          buffer: String.t(),
          started?: boolean(),
          blocks: map(),
          usage: map(),
          stop_reason: String.t()
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
    combined = state.buffer <> chunk
    {complete_lines, remaining_buffer} = split_complete_lines(combined)

    {events, next_state} =
      Enum.reduce(complete_lines, {[], %__MODULE__{state | buffer: remaining_buffer}}, fn line, {acc_events, st} ->
        {new_events, st2} = process_sse_line(st, String.trim_trailing(line, "\r"))
        {acc_events ++ new_events, st2}
      end)

    {events, next_state}
  end

  @doc """
  Flushes any remaining complete SSE data in the buffer and returns `{events, final_state}`.
  """
  @spec flush(t()) :: {list(tuple()), t()}
  def flush(%__MODULE__{buffer: ""} = state), do: {[], state}

  def flush(%__MODULE__{buffer: rest} = state) do
    {events, st} = process_sse_line(%__MODULE__{state | buffer: ""}, String.trim(rest))
    {events, st}
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
      same_origin? = to_string(msg_provider) == to_string(target_provider) and msg_model == target_model

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

  defp split_complete_lines(binary) do
    parts = String.split(binary, "\n")

    case Enum.split(parts, -1) do
      {complete, [last]} -> {complete, last}
      _ -> {[], binary}
    end
  end

  defp process_sse_line(state, ""), do: {[], state}
  defp process_sse_line(state, "event:" <> _), do: {[], state}
  defp process_sse_line(state, ":" <> _), do: {[], state}

  defp process_sse_line(state, "data:" <> raw_payload) do
    payload = String.trim(raw_payload)

    if payload == "[DONE]" do
      finalize_stream(state)
    else
      case Jason.decode(payload) do
        {:ok, decoded} when is_map(decoded) ->
          normalize_provider_event(state, decoded)

        {:error, reason} ->
          {[{:error, %{reason: {:invalid_sse_json, reason, payload}}}], state}
      end
    end
  end

  defp process_sse_line(state, _other), do: {[], state}

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
        {start_events, %__MODULE__{state | stop_reason: stop_reason, usage: merge_usage(state.usage, usage)}}

      "message_stop" ->
        {done_events, final_state} = finalize_stream(state)
        {start_events ++ done_events, final_state}

      "error" ->
        err = Map.get(event, "error", %{"message" => "unknown_error"})
        {start_events ++ [{:error, %{reason: err}}], state}

      _ ->
        {start_events, state}
    end
  end

  defp normalize_provider_event(%__MODULE__{provider: :openai} = state, event) do
    {start_events, state} = ensure_started(state)

    # Support both OpenAI Chat Completions deltas and Responses API events
    cond do
      is_list(Map.get(event, "choices")) ->
        choice = List.first(event["choices"]) || %{}
        delta = Map.get(choice, "delta", %{})
        finish = Map.get(choice, "finish_reason")
        {delta_events, %__MODULE__{} = st} = apply_openai_choice_delta(state, delta)
        st = if finish, do: %__MODULE__{st | stop_reason: finish}, else: st
        {start_events ++ delta_events, st}

      Map.get(event, "type") == "response.output_text.delta" ->
        idx = Map.get(event, "content_index", 0)
        text = Map.get(event, "delta", "")
        block = Map.get(state.blocks, idx, %{"type" => "text", "text" => ""})
        updated = Map.put(block, "text", block["text"] <> text)
        st = %__MODULE__{state | blocks: Map.put(state.blocks, idx, updated)}
        {start_events ++ [{:text_delta, %{index: idx, delta: text}}], st}

      true ->
        {start_events, state}
    end
  end

  defp normalize_provider_event(%__MODULE__{provider: :google} = state, event) do
    {start_events, state} = ensure_started(state)
    candidates = Map.get(event, "candidates", [])

    case List.first(candidates) do
      nil ->
        {start_events, state}

      cand ->
        parts = get_in(cand, ["content", "parts"]) || []

        {part_events, %__MODULE__{} = st} =
          Enum.with_index(parts)
          |> Enum.reduce({[], state}, fn {part, idx}, {ev_acc, %__MODULE__{} = s_acc} ->
            cond do
              Map.get(part, "thought") == true ->
                text = Map.get(part, "text", "")
                sig = Map.get(part, "thoughtSignature")
                thinking_idx = {:thinking, idx}
                block = Map.get(s_acc.blocks, thinking_idx, %{"type" => "thinking", "thinking" => "", "signature" => sig})
                prev_thinking = Map.get(block, "thinking", "") || ""
                updated = %{"type" => "thinking", "thinking" => prev_thinking <> text, "signature" => sig || block["signature"]}
                s_next = %__MODULE__{s_acc | blocks: Map.put(s_acc.blocks, thinking_idx, updated)}
                {ev_acc ++ [{:thinking_delta, %{index: idx, delta: text, signature: updated["signature"]}}], s_next}

              is_binary(Map.get(part, "text")) ->
                text = part["text"]
                sig = Map.get(part, "thoughtSignature")
                text_idx = {:text, idx}
                block = Map.get(s_acc.blocks, text_idx, %{"type" => "text", "text" => ""})
                prev_text = Map.get(block, "text", "") || ""
                updated = %{"type" => "text", "text" => prev_text <> text}
                updated = if sig, do: Map.put(updated, "thoughtSignature", sig), else: updated
                s_next = %__MODULE__{s_acc | blocks: Map.put(s_acc.blocks, text_idx, updated)}
                {ev_acc ++ [{:text_delta, %{index: idx, delta: text}}], s_next}

              is_map(Map.get(part, "functionCall")) ->
                fc = part["functionCall"]
                name = Map.get(fc, "name", "tool")
                id = Map.get(fc, "id", "fc_#{map_size(s_acc.blocks) + 1}")
                args = Map.get(fc, "args", %{})
                sig = Map.get(part, "thoughtSignature") || Map.get(fc, "thoughtSignature")
                raw_json = Jason.encode!(args)
                tool_idx = {:tool, map_size(s_acc.blocks) + 1}

                block = %{
                  "type" => "tool_call",
                  "id" => id,
                  "name" => name,
                  "raw_json" => raw_json,
                  "arguments" => args
                }

                block = if sig, do: Map.put(block, "thoughtSignature", sig), else: block
                s_next = %__MODULE__{s_acc | blocks: Map.put(s_acc.blocks, tool_idx, block)}

                ev =
                  {:toolcall_delta,
                   %{index: idx, id: id, name: name, raw_json_delta: raw_json, partial_args: args}}

                {ev_acc ++ [ev], s_next}

              true ->
                {ev_acc, s_acc}
            end
          end)

        finish = Map.get(cand, "finishReason")

        if finish in ["STOP", "MAX_TOKENS"] do
          {done_events, final_st} = finalize_stream(%__MODULE__{st | stop_reason: String.downcase(finish)})
          {start_events ++ part_events ++ done_events, final_st}
        else
          {start_events ++ part_events, st}
        end
    end
  end

  defp ensure_started(%__MODULE__{started?: true} = state), do: {[], state}

  defp ensure_started(%__MODULE__{started?: false} = state) do
    {[{:start, %{provider: state.provider, model: state.model}}], %__MODULE__{state | started?: true}}
  end

  defp init_block_from_anthropic(%{"type" => "thinking"}) do
    %{"type" => "thinking", "thinking" => "", "signature" => nil}
  end

  defp init_block_from_anthropic(%{"type" => "tool_use", "id" => id, "name" => name}) do
    %{"type" => "tool_call", "id" => id, "name" => name, "raw_json" => "", "arguments" => %{}}
  end

  defp init_block_from_anthropic(_other) do
    %{"type" => "text", "text" => ""}
  end

  defp apply_anthropic_delta(%__MODULE__{} = state, start_events, idx, %{"type" => "text_delta", "text" => chunk}) do
    block = Map.get(state.blocks, idx, %{"type" => "text", "text" => ""})
    updated = Map.put(block, "text", block["text"] <> chunk)
    next_state = %__MODULE__{state | blocks: Map.put(state.blocks, idx, updated)}
    {start_events ++ [{:text_delta, %{index: idx, delta: chunk}}], next_state}
  end

  defp apply_anthropic_delta(%__MODULE__{} = state, start_events, idx, %{"type" => "thinking_delta", "thinking" => chunk}) do
    block = Map.get(state.blocks, idx, %{"type" => "thinking", "thinking" => "", "signature" => nil})
    updated = Map.put(block, "thinking", block["thinking"] <> chunk)
    next_state = %__MODULE__{state | blocks: Map.put(state.blocks, idx, updated)}
    {start_events ++ [{:thinking_delta, %{index: idx, delta: chunk, signature: updated["signature"]}}], next_state}
  end

  defp apply_anthropic_delta(%__MODULE__{} = state, start_events, idx, %{"type" => "signature_delta", "signature" => sig_chunk}) do
    block = Map.get(state.blocks, idx, %{"type" => "thinking", "thinking" => "", "signature" => ""})
    prev_sig = block["signature"] || ""
    updated = Map.put(block, "signature", prev_sig <> sig_chunk)
    next_state = %__MODULE__{state | blocks: Map.put(state.blocks, idx, updated)}
    {start_events ++ [{:thinking_delta, %{index: idx, delta: "", signature: updated["signature"]}}], next_state}
  end

  defp apply_anthropic_delta(%__MODULE__{} = state, start_events, idx, %{"type" => "input_json_delta", "partial_json" => json_chunk}) do
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
    updated = %{"type" => "tool_call", "id" => block["id"], "name" => block["name"], "raw_json" => new_raw, "arguments" => partial}
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

  defp apply_anthropic_delta(%__MODULE__{} = state, start_events, _idx, _unknown_delta), do: {start_events, state}

  defp apply_openai_choice_delta(%__MODULE__{} = state, delta) do
    {events, %__MODULE__{} = state} =
      case Map.get(delta, "content") do
        text when is_binary(text) and text != "" ->
          block = Map.get(state.blocks, 0, %{"type" => "text", "text" => ""})
          updated = Map.put(block, "text", block["text"] <> text)
          {[{:text_delta, %{index: 0, delta: text}}], %__MODULE__{state | blocks: Map.put(state.blocks, 0, updated)}}

        _ ->
          {[], state}
      end

    case Map.get(delta, "tool_calls") do
      tc_list when is_list(tc_list) ->
        Enum.reduce(tc_list, {events, state}, fn tc, {ev_acc, %__MODULE__{} = st_acc} ->
          idx = Map.get(tc, "index", 0) + 1
          existing = Map.get(st_acc.blocks, idx, %{"type" => "tool_call", "id" => "call_#{idx}", "name" => "", "raw_json" => "", "arguments" => %{}})
          id = Map.get(tc, "id") || existing["id"]
          fn_map = Map.get(tc, "function", %{})
          name = Map.get(fn_map, "name") || existing["name"]
          arg_chunk = Map.get(fn_map, "arguments", "")
          new_raw = existing["raw_json"] <> arg_chunk
          partial = parse_partial_json(new_raw)

          updated = %{
            "type" => "tool_call",
            "id" => id,
            "name" => name,
            "raw_json" => new_raw,
            "arguments" => partial
          }

          ev = {:toolcall_delta, %{index: idx, id: id, name: name, raw_json_delta: arg_chunk, partial_args: partial}}
          {ev_acc ++ [ev], %__MODULE__{st_acc | blocks: Map.put(st_acc.blocks, idx, updated)}}
        end)

      _ ->
        {events, state}
    end
  end

  defp finalize_stream(state) do
    ordered_content =
      state.blocks
      |> Enum.sort_by(fn {idx, _} -> idx end)
      |> Enum.map(fn {_idx, block} ->
        case block do
          %{"type" => "tool_call", "raw_json" => raw} = tc ->
            final_args =
              case Jason.decode(raw) do
                {:ok, decoded} when is_map(decoded) -> decoded
                _ -> tc["arguments"]
              end

            tc
            |> Map.put("arguments", final_args)
            |> Map.delete("raw_json")

          other ->
            other
        end
      end)

    done_event =
      {:done,
       %{
         stop_reason: state.stop_reason,
         content: ordered_content,
         usage: state.usage
       }}

    {[done_event], state}
  end

  defp merge_usage(prev, incoming) when is_map(incoming) do
    %{
      "input_tokens" => Map.get(incoming, "input_tokens", prev["input_tokens"]),
      "output_tokens" => Map.get(incoming, "output_tokens", prev["output_tokens"]),
      "cache_read_tokens" => Map.get(incoming, "cache_read_input_tokens", prev["cache_read_tokens"])
    }
  end

  # Repairs truncated JSON strings/objects so partial tool arguments can be inspected live
  defp repair_truncated_json(str) do
    {in_string?, escaped?, stack} =
      str
      |> String.graphemes()
      |> Enum.reduce({false, false, []}, fn ch, {in_str, esc, stk} ->
        cond do
          esc ->
            {in_str, false, stk}

          ch == "\\" and in_str ->
            {in_str, true, stk}

          ch == "\"" ->
            {not in_str, false, stk}

          in_str ->
            {in_str, false, stk}

          ch == "{" ->
            {false, false, ["}" | stk]}

          ch == "[" ->
            {false, false, ["]" | stk]}

          ch in ["}", "]"] ->
            case stk do
              [^ch | rest] -> {false, false, rest}
              _ -> {false, false, stk}
            end

          true ->
            {false, false, stk}
        end
      end)

    base =
      cond do
        escaped? -> str <> "\\"
        true -> str
      end

    base = if in_string?, do: base <> "\"", else: base

    # Strip trailing dangling comma or colon before closing brackets
    trimmed = Regex.replace(~r/[,:\s]+$/, base, "")

    # If a key was just opened without a value (e.g. `{"a": 1, "b"`), append `: null`
     closed =
      if Regex.match?(~r/\{\s*"[^"]+"\s*$/, trimmed) or Regex.match?(~r/,\s*"[^"]+"\s*$/, trimmed) do
        trimmed <> ": null"
      else
        trimmed
      end

    closed <> Enum.join(stack, "")
  end
end
