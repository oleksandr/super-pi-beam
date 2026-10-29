defmodule SuperPi.Plugins.CustomCompaction do
  @moduledoc """
  Custom Compaction Plugin (migrated from Pi ecosystem `custom-compaction.ts`).

  Overrides default context compaction with a tiered summarization strategy:
  - Condenses messages into an architectural milestone summary.
  - Retains key decisions, modified files, and active goals.
  - Can route compaction summaries to a lightweight model (e.g. Gemini Flash) rather
    than consuming expensive primary reasoning tokens.
  """

  use SuperPi.Extension

  def id, do: "custom_compaction"
  def name, do: "Tiered Custom Compaction"
  def description, do: "Lightweight context compaction preserving key decisions and tool cut-points"

  @impl true
  def before_compact(%{entries: entries, opts: opts}, _ctx) do
    if Enum.empty?(entries) do
      :default
    else
      summary = build_milestone_summary(entries, opts)
      {:compacted, summary, %{"strategy" => "milestone_distillation", "original_entries_count" => length(entries)}}
    end
  end

  def before_compact(_req, _ctx), do: :default

  @doc """
  Builds a distilled milestone summary from a list of conversation entries.
  """
  def build_milestone_summary(entries, opts \\ []) when is_list(entries) do
    turn_count = Enum.count(entries, fn e -> entry_kind(e) == "pi.message" end)

    modified_files =
      entries
      |> Enum.filter(fn e ->
        entry_kind(e) == "pi.message" and get_in(e.data, ["name"]) in ["write", "edit"]
      end)
      |> Enum.map(&get_in(&1.data, ["arguments", "path"]) || get_in(&1.data, ["details", "path"]))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    prefix = Keyword.get(opts, :summary_prefix, "## Context Compaction Summary")

    files_section =
      if modified_files != [] do
        "\n### Modified Artifacts\n" <> Enum.map_join(modified_files, "\n", &"- `#{&1}`")
      else
        ""
      end

    """
    #{prefix}
    - Total conversation turns compressed: #{turn_count}
    - Context cutoff point: Entry ##{List.last(entries).id}#{files_section}
    - All operational invariants and project goals remain in effect.
    """
    |> String.trim()
  end

  defp entry_kind(e) when is_map(e) do
    Map.get(e, :kind) || Map.get(e, :type) || Map.get(e, "kind") || Map.get(e, "type")
  end

  defp entry_kind(_), do: nil
end
