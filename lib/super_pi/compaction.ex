defmodule SuperPi.Compaction do
  @moduledoc """
  4-Mode Context Compaction Engine (`Decision 08`, `REQ-PBT-06`).

  Supports all 4 compaction modes:
  1. `:manual` — User or RPC explicitly triggers `/compact` with optional custom instructions.
  2. `:threshold` — Synchronous turn-boundary compaction when `current_tokens + reserve_tokens >= context_window`
     (`reserve_tokens: 16_384`, `keep_recent_tokens: 20_000`).
  3. `:background` — Asynchronous Oban worker (`SuperPi.Workers.CompactionWorker`) triggered when
     `current_tokens >= background_tokens`; summarizes older turns concurrently and appends a
     non-destructive `pi.compaction` entry (`head_entry_id`) without blocking the active stream.
  4. `:overflow` — Auto-recovery compaction when an LLM provider returns a context-window overflow error;
     compacts with a tighter `keep_recent_tokens` budget and signals immediate retry.

  ## Cut-Point Tool-Pair Invariant (`REQ-PBT-06`)
  `find_safe_cut_point/2` walks backwards from the end of `visible_entries` until `keep_recent_tokens`
  is accumulated, and then advances/adjusts the cut index so that **no `tool_call` assistant entry is ever
  separated from its corresponding `role: "tool"` result entries**. Every `tool` result in the kept tail
  is guaranteed to have its originating `assistant` `tool_call` also in the kept tail.
  """

  alias SuperPi.Durable.{Context, Storage}
  alias SuperPi.Durable.Schemas.Entry
  alias SuperPi.Workers.CompactionWorker

  @default_reserve_tokens 16_384
  @default_keep_recent_tokens 20_000
  @default_context_window 200_000
  @default_background_tokens 140_000

  @doc """
  Estimates token count for an entry (`~4 chars per token` heuristic).
  """
  def estimate_entry_tokens(%Entry{data: data}) when is_map(data) do
    json_bytes = byte_size(Jason.encode!(data))
    max(div(json_bytes, 4), 1)
  end

  def estimate_total_tokens(entries) when is_list(entries) do
    Enum.reduce(entries, 0, fn e, acc -> acc + estimate_entry_tokens(e) end)
  end

  @doc """
  Computes `{compacted_prefix, kept_tail, head_entry_id}` for `visible_entries` given `keep_recent_tokens`.

  Guarantees the **Tool-Pair Cut-Point Invariant (`REQ-PBT-06`)**:
  - `kept_tail` never starts on a `role == "tool"` message entry.
  - Every `role == "tool"` entry in `kept_tail` has its preceding `role == "assistant"` tool-call entry
    included in `kept_tail` as well.
  """
  def find_safe_cut_point([], _keep_recent_tokens), do: {[], [], nil}

  def find_safe_cut_point(visible_entries, keep_recent_tokens)
      when is_list(visible_entries) and is_integer(keep_recent_tokens) do
    message_entries = Enum.filter(visible_entries, &(&1.kind == "pi.message"))

    if length(message_entries) <= 1 do
      {[], visible_entries, List.first(visible_entries) && List.first(visible_entries).id}
    else
      # Walk backwards from the end of visible_entries accumulating tokens up to keep_recent_tokens
      total_len = length(visible_entries)

      raw_cut_idx =
        visible_entries
        |> Enum.with_index(0)
        |> Enum.reverse()
        |> Enum.reduce_while({0, total_len - 1}, fn {entry, idx}, {acc_tokens, last_idx} ->
          next_tokens = acc_tokens + estimate_entry_tokens(entry)

          if next_tokens > keep_recent_tokens and last_idx < total_len - 1 do
            {:halt, {acc_tokens, last_idx}}
          else
            {:cont, {next_tokens, idx}}
          end
        end)
        |> elem(1)

      # Ensure we compact at least 1 entry if raw_cut_idx == 0 and there are multiple turns
      initial_idx = max(raw_cut_idx, 1)

      # Adjust `initial_idx` backwards if it lands on a `role == "tool"` message so we never orphan
      # a tool result from its preceding assistant `tool_call` message (`REQ-PBT-06`).
      safe_idx =rewind_before_tool_sequence(visible_entries, initial_idx)

      {prefix, tail} = Enum.split(visible_entries, safe_idx)

      case tail do
        [%Entry{id: first_kept_id} | _] ->
          {prefix, tail, first_kept_id}

        [] ->
          last = List.last(visible_entries)
          {Enum.drop(visible_entries, -1), [last], last.id}
      end
    end
  end

  @doc """
  Evaluates whether `:threshold` or `:background` compaction should run based on current token usage.
  Returns `:none`, `{:threshold, meta}`, or `{:background, meta}`.
  """
  def check_policy(conversation_id, opts \\ []) do
    reserve_tokens = Keyword.get(opts, :reserve_tokens, @default_reserve_tokens)
    context_window = Keyword.get(opts, :context_window, @default_context_window)
    background_tokens = Keyword.get(opts, :background_tokens, @default_background_tokens)

    entries =
      if opts == [] do
        {visible, _} = Context.visible_entries_with_graph(conversation_id)
        visible
      else
        Context.derive(conversation_id).active_entries
      end

    current_tokens = estimate_total_tokens(entries)

    cond do
      current_tokens + reserve_tokens >= context_window ->
        {:threshold, %{current_tokens: current_tokens, context_window: context_window}}

      current_tokens >= background_tokens ->
        {:background, %{current_tokens: current_tokens, background_tokens: background_tokens}}

      true ->
        :none
    end
  end

  @doc """
  Executes compaction in one of the 4 modes (`:manual`, `:threshold`, `:background`, `:overflow`).
  - For `:background` with `enqueue: true`, schedules an asynchronous `Oban` job on the `:compaction` queue.
  - Otherwise computes the safe cut point (`find_safe_cut_point/2`), summarizes the prefix, and appends a
    durable `pi.compaction` entry with `head_entry_id: first_kept_id`.
  """
  @spec compact!(integer(), atom(), keyword()) ::
          {:ok, :noop}
          | {:ok, map()}
          | {:enqueued, Oban.Job.t()}
  def compact!(conversation_id, mode \\ :manual, opts \\ [])
      when mode in [:manual, :threshold, :background, :overflow] do
    keep_recent_tokens =
      case mode do
        :overflow -> Keyword.get(opts, :keep_recent_tokens, div(@default_keep_recent_tokens, 2))
        _ -> Keyword.get(opts, :keep_recent_tokens, @default_keep_recent_tokens)
      end

    if mode == :background and Keyword.get(opts, :enqueue, false) do
      {:ok, job} =
        %{"conversation_id" => conversation_id, "keep_recent_tokens" => keep_recent_tokens}
        |> CompactionWorker.new()
        |> Oban.insert()

      {:enqueued, job}
    else
      {all_visible, _} = Context.visible_entries_with_graph(conversation_id)

      # Find any previous compaction head cutoff
      prev_head_id =
        Enum.reverse(all_visible)
        |> Enum.find_value(fn
          %Entry{head_entry_id: hid} when is_integer(hid) -> hid
          _ -> nil
        end)

      # Eligible entries are active entries (from prev_head_id onwards, ignoring existing compaction markers)
      eligible_entries =
        if prev_head_id do
          Enum.filter(all_visible, fn e -> e.id >= prev_head_id and e.kind != "pi.compaction" end)
        else
          all_visible
        end

      eligible_messages = Enum.filter(eligible_entries, &(&1.kind == "pi.message"))

      if length(eligible_messages) <= 1 do
        {:ok, :noop}
      else
        {prefix, tail, raw_head_id} = find_safe_cut_point(eligible_entries, keep_recent_tokens)
        head_entry_id = if prev_head_id, do: max(raw_head_id || 0, prev_head_id), else: raw_head_id

        summarizer = Keyword.get(opts, :summarizer, &default_summarizer/2)
        summary_text = summarizer.(prefix, mode)

        entry =
          Storage.append_entry!(
            conversation_id,
            "pi.compaction",
            %{
              "summary" => summary_text,
              "mode" => Atom.to_string(mode),
              "compactedCount" => length(prefix),
              "keptCount" => length(tail)
            },
            head_entry_id: head_entry_id
          )

        {:ok,
         %{
           entry: entry,
           mode: mode,
           head_entry_id: head_entry_id,
           compacted_count: length(prefix),
           kept_count: length(tail),
           summary: summary_text
         }}
      end
    end
  end

  # --- Private Helpers ---

  defp rewind_before_tool_sequence(_entries, idx) when idx <= 0, do: 0

  defp rewind_before_tool_sequence(entries, idx) do
    case Enum.at(entries, idx) do
      %Entry{kind: "pi.message", data: %{"role" => "tool"}} ->
        rewind_before_tool_sequence(entries, idx - 1)

      _ ->
        idx
    end
  end

  defp default_summarizer(prefix, mode) do
    msg_count = Enum.count(prefix, &(&1.kind == "pi.message"))
    "[#{mode} compaction summary covering #{msg_count} historical messages]"
  end
end
