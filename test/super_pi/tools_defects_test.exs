defmodule SuperPi.ToolsDefectsTest do
  @moduledoc """
  Regression tests that reproduce SuperPi.Tools defects found in the code review.
  Every test is expected to FAIL on the current code and pass once the matching
  finding is fixed.

  Run only these:  mix test --only known_bug
  Skip these:      mix test --exclude known_bug
  """
  use ExUnit.Case, async: false

  alias SuperPi.Tools

  @table :super_pi_tool_catalog

  setup do
    # Tests below delete the catalog table; make sure it exists again afterwards.
    on_exit(fn ->
      if :ets.whereis(@table) == :undefined, do: Tools.ensure_catalog_ets!()
    end)

    :ok
  end

  defp drop_table do
    if :ets.whereis(@table) != :undefined, do: :ets.delete(@table)
  end

  describe "catalog ETS ownership (tools.ex:26-36)" do
    test "registered tools survive the exit of the process that created the table" do
      drop_table()

      {pid, ref} =
        spawn_monitor(fn ->
          Tools.register_tool!(%{"name" => "zz_survivor_tool", "description" => "x"}, :direct)
        end)

      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000

      assert :ets.whereis(@table) != :undefined, "catalog table died with its first caller"
      assert [{"zz_survivor_tool", _}] = :ets.lookup(@table, "zz_survivor_tool")
    end

    test "concurrent first callers do not race on :ets.new" do
      drop_table()
      parent = self()

      pids =
        for _ <- 1..50 do
          spawn(fn ->
            receive do
              :go ->
                result =
                  try do
                    Tools.ensure_catalog_ets!()
                    :ok
                  rescue
                    e -> {:raised, e}
                  end

                send(parent, {:done, self(), result})
            end
          end)
        end

      Enum.each(pids, &send(&1, :go))

      results =
        for pid <- pids do
          assert_receive {:done, ^pid, result}, 5_000
          result
        end

      raised = Enum.filter(results, &match?({:raised, _}, &1))

      assert raised == [],
             "#{length(raised)} callers raised, first: #{inspect(List.first(raised))}"
    end
  end

  describe "tool_search (tools.ex:66-79)" do
    test "does not activate :codemode-only tools via control.add_tools" do
      on_exit(fn ->
        if :ets.whereis(@table) != :undefined, do: :ets.delete(@table, "zz_codemode_only")
      end)

      Tools.register_tool!(
        %{"name" => "zz_codemode_only", "description" => "script only"},
        :codemode
      )

      result = Tools.tool_search("zz_codemode_only")
      added = Enum.map(result["control"]["add_tools"], & &1["name"])

      refute "zz_codemode_only" in added
    end

    test "an empty query does not match every tool" do
      result = Tools.tool_search("")

      assert result["structured_output"]["count"] == 0
      assert result["control"]["add_tools"] == []
    end
  end

  describe "malformed arguments must yield an error result, not raise (tools.ex:95,260-264)" do
    @bad_calls [
      {"non-map args", "read", "not a map"},
      {"nil args", "read", nil},
      {"list args", "ls", []},
      {"non-string tool_search query", "tool_search", %{"query" => 123}},
      {"non-string tool_search query (list)", "tool_search", %{"query" => ["a"]}}
    ]

    for {label, tool, args} <- @bad_calls do
      test label do
        outcome =
          try do
            {:ok, Tools.execute(unquote(tool), unquote(Macro.escape(args)))}
          rescue
            e -> {:raised, e}
          end

        assert {:ok, %{"is_error" => true}} = outcome, "got #{inspect(outcome)}"
      end
    end
  end

  describe "find tool ignores its declared `pattern` (tools.ex:219-232)" do
    test "find with pattern \"*.ex\" returns only matching files" do
      dir = Path.join(System.tmp_dir!(), "tools_find_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      File.write!(Path.join(dir, "a.ex"), "")
      File.write!(Path.join(dir, "b.txt"), "")

      result = Tools.execute("find", %{"path" => dir, "pattern" => "*.ex"})

      assert result["structured_output"]["files"] == ["a.ex"]
    end
  end
end
