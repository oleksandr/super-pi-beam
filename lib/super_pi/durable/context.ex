defmodule SuperPi.Durable.Context do
  @moduledoc """
  Normative 10-Rule Context Derivation Engine (`packages/durable/docs/spec.md` §2.1).

  Responsibilities:
  1. Walk conversation fork ancestry (`libgraph` DAG) to collect visible entries in order.
  2. Replay positional `pi.system` entries (`full` baseline + `delta` prompt sections and tools)
     and append minimal `delta` entries when configuration changes so provider prompt caches stay warm.
  3. Slice the active window from the newest visible `head_entry_id` marker (`pi.compaction` or `pi.reset`).
  4. Apply non-destructive `ContextEdit` operations (`omit` and `replace`) in entry order.
  """

  import Ecto.Query
  alias SuperPi.Repo
  alias SuperPi.Durable.Storage
  alias SuperPi.Durable.Schemas.{Conversation, Entry}

  @type derived_context :: %{
          conversation_id: integer(),
          ancestry_graph: Graph.t(),
          system_sections: [%{String.t() => String.t()}],
          system_prompt: String.t(),
          tools: [map()],
          head_marker_entry_id: integer() | nil,
          active_entries: [Entry.t()],
          messages: [map()]
        }

  @doc """
  Builds the fork ancestry DAG (`Graph`) and returns all visible entries for `conversation_id`
  in chronological order, respecting `parent_entry_id` fork cutoffs.
  """
  @spec visible_entries_with_graph(integer()) :: {[Entry.t()], Graph.t()}
  def visible_entries_with_graph(conversation_id) do
    chain = build_ancestry_chain(conversation_id, nil, [])

    graph =
      Enum.reduce(chain, Graph.new(type: :directed), fn
        {conv_id, nil, _max_entry_id}, g ->
          Graph.add_vertex(g, conv_id)

        {conv_id, parent_id, max_entry_id}, g ->
          g
          |> Graph.add_vertex(parent_id)
          |> Graph.add_vertex(conv_id)
          |> Graph.add_edge(parent_id, conv_id, label: {:fork_at, max_entry_id})
      end)

    entries =
      Enum.flat_map(chain, fn {conv_id, _parent_id, max_entry_id} ->
        query =
          from(e in Entry,
            where: e.conversation_id == ^conv_id,
            order_by: [asc: e.id]
          )

        query =
          if is_integer(max_entry_id) do
            from(e in query, where: e.id <= ^max_entry_id)
          else
            query
          end

        Repo.all(query)
      end)

    {entries, graph}
  end

  @doc """
  Derives the active LLM context for `conversation_id` according to the 10-rule specification.
  `visible` is the result of `visible_entries_with_graph/1` when the caller already has it.
  """
  @spec derive(integer(), {[Entry.t()], Graph.t()} | nil) :: derived_context()
  def derive(conversation_id, visible \\ nil) do
    {all_visible, graph} = visible || visible_entries_with_graph(conversation_id)
    {sections, tools} = replay_system_entries(all_visible)

    {head_marker, sliced_entries} = apply_head_cutoff(all_visible)
    edited_entries = apply_context_edits(sliced_entries)

    messages =
      edited_entries
      |> Enum.flat_map(&project_entry_to_messages/1)
      |> repair_tool_pairs()

    system_prompt =
      sections
      |> Enum.map(&Map.get(&1, "content", ""))
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    %{
      conversation_id: conversation_id,
      ancestry_graph: graph,
      system_sections: sections,
      system_prompt: system_prompt,
      tools: tools,
      head_marker_entry_id: if(head_marker, do: head_marker.id, else: nil),
      active_entries: edited_entries,
      messages: messages
    }
  end

  @doc """
  Compares `desired_sections` and `desired_tools` against the conversation's replayed `pi.system`
  state. Appends a `"full"` baseline on first request, a `"delta"` entry only when a section or tool
  changed, or nothing when unchanged (preserving LLM prompt cache prefixes).
  """
  @spec ensure_system_state!(integer(), [map()], [map()], [Entry.t()] | nil) ::
          {:unchanged | :full | :delta, Entry.t() | nil}
  def ensure_system_state!(conversation_id, desired_sections, desired_tools, visible \\ nil) do
    all_visible = visible || conversation_id |> visible_entries_with_graph() |> elem(0)
    system_entries = Enum.filter(all_visible, &(&1.kind == "pi.system"))

    norm_sections = normalize_sections(desired_sections)
    norm_tools = normalize_tools(desired_tools)

    case system_entries do
      [] ->
        entry =
          Storage.append_entry!(conversation_id, "pi.system", %{
            "mode" => "full",
            "sections" => norm_sections,
            "tools" => norm_tools
          })

        {:full, entry}

      _ ->
        {current_sections, current_tools} = replay_system_entries(system_entries)
        section_deltas = diff_sections(current_sections, norm_sections)
        {tools_added, tools_removed} = diff_tools(current_tools, norm_tools)

        if section_deltas == [] and tools_added == [] and tools_removed == [] do
          {:unchanged, nil}
        else
          entry =
            Storage.append_entry!(conversation_id, "pi.system", %{
              "mode" => "delta",
              "sectionsChanged" => section_deltas,
              "toolsAdded" => tools_added,
              "toolsRemoved" => tools_removed
            })

          {:delta, entry}
        end
    end
  end

  defp build_ancestry_chain(conv_id, cutoff_entry_id, acc) do
    case Repo.get(Conversation, conv_id) do
      nil ->
        acc

      %Conversation{parent_conversation_id: nil} ->
        [{conv_id, nil, cutoff_entry_id} | acc]

      %Conversation{parent_conversation_id: parent_id, parent_entry_id: parent_entry_id} ->
        build_ancestry_chain(parent_id, parent_entry_id, [
          {conv_id, parent_id, cutoff_entry_id} | acc
        ])
    end
  end

  defp replay_system_entries(entries) do
    entries
    |> Enum.filter(&(&1.kind == "pi.system"))
    |> Enum.reduce({[], []}, fn entry, {sections, tools} ->
      case entry.data["mode"] do
        "full" ->
          {entry.data["sections"] || [], entry.data["tools"] || []}

        "delta" ->
          next_sections = apply_section_deltas(sections, entry.data["sectionsChanged"] || [])

          next_tools =
            apply_tool_deltas(
              tools,
              entry.data["toolsAdded"] || [],
              entry.data["toolsRemoved"] || []
            )

          {next_sections, next_tools}

        _ ->
          {sections, tools}
      end
    end)
  end

  defp apply_section_deltas(sections, deltas) do
    Enum.reduce(deltas, sections, fn
      %{"id" => id, "content" => nil}, acc ->
        Enum.reject(acc, &(&1["id"] == id))

      %{"id" => id, "content" => content}, acc ->
        if Enum.any?(acc, &(&1["id"] == id)) do
          Enum.map(acc, fn s ->
            if s["id"] == id, do: %{"id" => id, "content" => content}, else: s
          end)
        else
          acc ++ [%{"id" => id, "content" => content}]
        end
    end)
  end

  defp apply_tool_deltas(tools, added, removed) do
    removed_set = MapSet.new(removed)

    kept =
      tools
      |> Enum.reject(&MapSet.member?(removed_set, &1["name"]))

    Enum.reduce(added, kept, fn tool, acc ->
      name = tool["name"]

      if Enum.any?(acc, &(&1["name"] == name)) do
        Enum.map(acc, fn t -> if t["name"] == name, do: tool, else: t end)
      else
        acc ++ [tool]
      end
    end)
  end

  defp apply_head_cutoff(entries) do
    case Enum.reverse(entries) |> Enum.find(&(not is_nil(&1.head_entry_id))) do
      nil ->
        {nil, entries}

      %Entry{kind: "pi.compaction", head_entry_id: first_kept_id} = comp_entry ->
        kept =
          entries
          |> Enum.filter(fn e ->
            (e.id >= first_kept_id and e.id != comp_entry.id) or e.kind == "pi.system"
          end)

        {comp_entry, [comp_entry | kept]}

      %Entry{head_entry_id: cutoff_id} = reset_entry ->
        kept =
          entries
          |> Enum.filter(fn e -> e.id >= cutoff_id or e.kind == "pi.system" end)

        {reset_entry, kept}
    end
  end

  defp apply_context_edits(entries) do
    all_edits =
      Enum.flat_map(entries, fn entry ->
        Map.get(entry.edits || %{}, "items", [])
      end)

    Enum.reduce(all_edits, entries, fn
      %{"op" => "omit", "target_id" => target_id}, acc ->
        Enum.reject(acc, &(&1.id == target_id))

      %{"op" => "replace", "target_id" => target_id, "replacement" => replacement}, acc
      when is_map(replacement) ->
        Enum.map(acc, fn %Entry{} = e ->
          if e.id == target_id, do: %Entry{e | data: replacement}, else: e
        end)

      _, acc ->
        acc
    end)
  end

  # Providers refuse a history where a tool call has no result, or where a user message comes
  # between an assistant's tool calls and their results (Anthropic and OpenAI return 400). The
  # machine no longer stores such a history, but older conversations can hold one. So the results
  # of each assistant entry move right after it, in call order, and a missing one is added.
  defp repair_tool_pairs([]), do: []

  defp repair_tool_pairs([%{"role" => "assistant", "content" => content} = msg | rest])
       when is_list(content) do
    case for(%{"type" => "tool_call", "id" => id} <- content, do: id) do
      [] ->
        [msg | repair_tool_pairs(rest)]

      call_ids ->
        {segment, later} = Enum.split_while(rest, &(&1["role"] != "assistant"))
        id_set = MapSet.new(call_ids)

        {results, others} =
          Enum.split_with(
            segment,
            &(&1["role"] == "tool" and MapSet.member?(id_set, &1["tool_call_id"]))
          )

        by_id = results |> Enum.reverse() |> Map.new(&{&1["tool_call_id"], &1})

        ordered =
          for %{"type" => "tool_call", "id" => id} = call <- content do
            Map.get_lazy(by_id, id, fn -> missing_tool_result(call) end)
          end

        [msg | ordered] ++ others ++ repair_tool_pairs(later)
    end
  end

  defp repair_tool_pairs([msg | rest]), do: [msg | repair_tool_pairs(rest)]

  defp missing_tool_result(call) do
    %{
      "role" => "tool",
      "tool_call_id" => call["id"],
      "name" => call["name"],
      "is_error" => true,
      "content" => "Tool call has no result: the turn was interrupted.",
      "structured_output" => nil,
      "details" => %{"repaired" => true}
    }
  end

  defp project_entry_to_messages(%Entry{kind: "pi.message", data: data}), do: [data]

  defp project_entry_to_messages(%Entry{kind: "pi.compaction", data: data}) do
    summary = Map.get(data, "summary", "")
    [%{"role" => "user", "kind" => "compaction_summary", "content" => summary}]
  end

  defp project_entry_to_messages(%Entry{kind: "pi.reset", data: data}) do
    case Map.get(data, "handoffPrompt") do
      prompt when is_binary(prompt) and prompt != "" ->
        [%{"role" => "user", "kind" => "reset_handoff", "content" => prompt}]

      _ ->
        []
    end
  end

  defp project_entry_to_messages(_other), do: []

  defp normalize_sections(sections) do
    Enum.map(sections, fn s ->
      %{
        "id" => to_string(Map.get(s, "id") || Map.get(s, :id)),
        "content" => to_string(Map.get(s, "content") || Map.get(s, :content, ""))
      }
    end)
  end

  # The parameter schema goes to the model, so it must survive. MCP tools name it `input_schema`.
  defp normalize_tools(tools) do
    Enum.map(tools, fn t ->
      name = to_string(Map.get(t, "name") || Map.get(t, :name))

      %{
        "name" => name,
        "description" => to_string(Map.get(t, "description") || Map.get(t, :description, "")),
        "parameters" => SuperPi.AI.ToolSchemas.parameters(t, name)
      }
    end)
  end

  defp diff_sections(old_sections, new_sections) do
    old_map = Map.new(old_sections, &{&1["id"], &1["content"]})
    new_map = Map.new(new_sections, &{&1["id"], &1["content"]})

    changed_or_added =
      Enum.flat_map(new_sections, fn %{"id" => id, "content" => content} ->
        if Map.get(old_map, id) == content, do: [], else: [%{"id" => id, "content" => content}]
      end)

    removed =
      old_sections
      |> Enum.reject(&Map.has_key?(new_map, &1["id"]))
      |> Enum.map(&%{"id" => &1["id"], "content" => nil})

    changed_or_added ++ removed
  end

  defp diff_tools(old_tools, new_tools) do
    old_map = Map.new(old_tools, &{&1["name"], &1})
    new_map = Map.new(new_tools, &{&1["name"], &1})

    tools_added =
      Enum.filter(new_tools, fn t ->
        Map.get(old_map, t["name"]) != t
      end)

    tools_removed =
      old_tools
      |> Enum.reject(&Map.has_key?(new_map, &1["name"]))
      |> Enum.map(& &1["name"])

    {tools_added, tools_removed}
  end
end
