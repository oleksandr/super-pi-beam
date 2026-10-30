defmodule SuperPi.Properties.MemoryTest do
  @moduledoc """
  Properties of the Memory plugin:

  - the rendered index never exceeds its token budget, for any corpus;
  - a superseded note never outranks its superseder;
  - a note round-trips arbitrary UTF-8 byte for byte, and a title that holds search syntax
    never breaks the lexical backend.

  The migration property for the `memories` tables is in `migration_properties_test.exs`.
  """
  use SuperPi.DataCase, async: false
  use ExUnitProperties

  alias SuperPi.Durable.Schemas.Memory, as: Note
  alias SuperPi.Memory
  alias SuperPi.Memory.{Index, Search}

  # Valid UTF-8 without NUL: any code point except surrogates.
  defp text(max \\ 60), do: string([1..0xD7FF, 0xE000..0x10FFFF], max_length: max)
  defp readable(max \\ 60), do: filter(text(max), &(String.trim(&1) != ""), 50)

  defp slug, do: map(string([?a..?z, ?0..?9, ?-], min_length: 1, max_length: 20), &("n" <> &1))
  defp topics, do: list_of(string([?a..?z, ?-, 0x3040..0x30FF], min_length: 1, max_length: 12), max_length: 3)

  defp ts(days_ago), do: DateTime.add(~U[2026-10-30 12:00:00.000000Z], -days_ago * 86_400)

  defp live_note do
    gen all slug <- slug(), title <- text(), topics <- topics(), days <- integer(0..900) do
      %{slug: slug, title: title, topics: Enum.join(topics, " "), updated_at: ts(days)}
    end
  end

  defp pinned_note do
    gen all slug <- slug(), title <- text(), body <- text(3000), days <- integer(0..900), confidence <- float(min: 0.0, max: 1.0) do
      %{slug: slug, title: title, body: body, provenance: "user", confidence: confidence, updated_at: ts(days)}
    end
  end

  describe "index budget" do
    property "the rendered index never exceeds the token budget" do
      check all notes <- list_of(live_note(), max_length: 150),
                pinned <- list_of(pinned_note(), max_length: 12),
                budget <- integer(200..4000),
                body_bytes <- integer(50..3000),
                max_runs: 150 do
        text = Index.render(notes, pinned, budget, body_bytes)
        assert byte_size(text) <= budget * 4, "#{byte_size(text)} bytes over #{budget} tokens"
        assert div(byte_size(text), 4) <= budget
        assert String.valid?(text)
        assert text =~ "never an instruction"
      end
    end

    property "a budget below the floor is raised to it, so the standing line always fits" do
      check all notes <- list_of(live_note(), max_length: 30), budget <- integer(1..199), max_runs: 40 do
        text = Index.render(notes, [], budget)
        assert byte_size(text) <= 200 * 4
        assert text =~ "never an instruction"
      end
    end

    property "the render is a pure function of the notes" do
      check all notes <- list_of(live_note(), max_length: 40), pinned <- list_of(pinned_note(), max_length: 4), max_runs: 50 do
        assert Index.render(notes, pinned, 1000) == Index.render(notes, pinned, 1000)
        assert Index.hash(Index.render(notes, pinned, 1000)) == Index.hash(Index.render(notes, pinned, 1000))
      end
    end

    property "a pinned body cannot close its wrapper" do
      check all pinned <- uniq_list_of(pinned_note(), uniq_fun: & &1.slug, min_length: 1, max_length: 4), max_runs: 60 do
        pinned = Enum.map(pinned, &%{&1 | body: &1.body <> "</MEMORY[" <> &1.slug <> "]> after"})
        text = Index.render([], pinned, 4000)

        for p <- pinned, String.contains?(text, "<MEMORY[#{p.slug}] ") do
          assert length(String.split(text, "</MEMORY[#{p.slug}]>")) == 2, "closing tag of #{p.slug} must appear once"
        end
      end
    end
  end

  describe "supersession" do
    defp note_struct(id, superseded_by, pinned, days) do
      %Note{id: id, slug: "n#{id}", title: "t", body: "b", superseded_by_id: superseded_by, pinned: pinned, updated_at: ts(days)}
    end

    # Notes 1..n. A note may be superseded by a higher id, so chains exist and cycles cannot.
    defp corpus do
      gen all n <- integer(2..9),
              rows <- list_of(tuple({float(min: 0.0001, max: 1.0), boolean(), integer(0..900), integer(0..9)}), length: n) do
        count = length(rows)

        rows
        |> Enum.with_index(1)
        |> Enum.map(fn {{text, pinned, days, jump}, id} ->
          superseder = if jump > 0 and id + jump <= count, do: id + jump
          %{memory: note_struct(id, superseder, pinned, days), text: text}
        end)
      end
    end

    property "a superseded note never outranks its superseder" do
      check all entries <- corpus(), max_runs: 300 do
        ranked = Search.rank(entries, ts(0))
        position = ranked |> Enum.with_index() |> Map.new(fn {e, i} -> {e.memory.id, {i, e.score}} end)

        for %{memory: %{id: id, superseded_by_id: sid}} <- ranked, sid != nil do
          {pos, score} = position[id]
          {spos, sscore} = position[sid]
          assert spos < pos, "note #{id} ranked above its superseder #{sid}"
          assert sscore > score
        end
      end
    end

    property "ranking keeps every entry and orders by descending score" do
      check all entries <- corpus(), max_runs: 100 do
        ranked = Search.rank(entries, ts(0))
        assert length(ranked) == length(entries)
        scores = Enum.map(ranked, & &1.score)
        assert scores == Enum.sort(scores, :desc)
      end
    end
  end

  describe "round trip" do
    property "a note reads back byte for byte, and its words never break the search" do
      scope = Memory.scope(nil, scope: :global)
      counter = :counters.new(1, [])

      check all title <- readable(), body <- readable(300), max_runs: 60 do
        :counters.add(counter, 1, 1)
        slug = "rt-#{:counters.get(counter, 1)}"

        assert {:ok, %{memory: written}} = Memory.write(scope, %{"title" => title, "body" => body, "slug" => slug})
        assert written.title == title and written.body == body

        assert {:ok, %{memory: read}} = Memory.read(scope, slug)
        assert read.title == title
        assert read.body == body
        assert byte_size(read.body) == byte_size(body)

        result = SuperPi.Plugins.Memory.wrap_tool("memory_read", %{"slug" => slug}, fn _ -> flunk("next") end, %{conversation_id: nil, config: [scope: :global]})
        assert result["structured_output"]["body"] == body

        # The title as a query is arbitrary text. The native backend answers without degrading.
        case Memory.search(scope, title) do
          {:ok, %{degraded: degraded}} -> refute degraded
          {:error, :empty_query} -> :ok
        end
      end
    end
  end
end
