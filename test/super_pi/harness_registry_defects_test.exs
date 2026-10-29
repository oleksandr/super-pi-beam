defmodule SuperPi.HarnessRegistryDefectsTest do
  @moduledoc """
  Regression tests that reproduce extension contract, plugin resolution and harness
  registry defects found in the code review (see vault note "20 - Codebase Review
  Findings"). Every test is expected to FAIL on the current code and pass once the
  matching finding is fixed.

  Run only these:  mix test --only known_bug
  Skip these:      mix test --exclude known_bug
  """
  use SuperPi.DataCase, async: false

  alias SuperPi.Conversation.Machine
  alias SuperPi.Durable.Storage
  alias SuperPi.Extension
  alias SuperPi.Harness
  alias SuperPi.Plugins
  alias SuperPi.TestSupport.Faults

  @moduletag :known_bug

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  defmodule ExtraHarness do
    @behaviour SuperPi.Harness
    def id, do: "test-extra-harness"
    def name, do: "Extra"
    def description, do: "extra"
    def extensions(_opts \\ []), do: []
    def agent_defaults(_opts \\ []), do: %{}
  end

  # Implements the behaviour but not `use SuperPi.Extension`; only one hook.
  defmodule OnlyAfterRun do
    @behaviour SuperPi.Extension
    @impl true
    def after_run(_summary, _ctx), do: :accept
  end

  defmodule OnlyOnInput do
    @behaviour SuperPi.Extension
    @impl true
    def on_input(_input, _ctx), do: :continue
  end

  describe "optional extension callbacks (extension.ex:149-289)" do
    @ctx %{conversation_id: 1}

    test "run_on_input skips a module without on_input" do
      assert {:continue, "x", []} = Extension.run_on_input([OnlyAfterRun], "x", @ctx)
    end

    test "run_before_agent_start skips a module without the hook" do
      assert %{"a" => 1} = Extension.run_before_agent_start([OnlyAfterRun], %{"a" => 1}, @ctx)
    end

    test "run_before_compact skips a module without the hook" do
      assert :default = Extension.run_before_compact([OnlyAfterRun], %{entries: [], opts: []}, @ctx)
    end

    test "run_before_request skips a module without the hook" do
      assert %{m: 1} = Extension.run_before_request([OnlyAfterRun], %{m: 1}, @ctx)
    end

    test "run_before_provider_request skips a module without the hook" do
      assert {:ok, %{p: 1}} = Extension.run_before_provider_request([OnlyAfterRun], %{p: 1}, @ctx)
    end

    test "run_after_response skips a module without the hook" do
      assert %{"r" => 1} = Extension.run_after_response([OnlyAfterRun], %{"r" => 1}, @ctx)
    end

    test "run_before_tool skips a module without the hook" do
      assert {:allow, %{}} = Extension.run_before_tool([OnlyAfterRun], "bash", %{}, @ctx)
    end

    test "run_wrap_tool skips a module without the hook" do
      assert %{"out" => 1} = Extension.run_wrap_tool([OnlyAfterRun], "bash", %{}, fn _ -> %{"out" => 1} end, @ctx)
    end

    test "run_after_tool skips a module without the hook" do
      assert %{"o" => 1} = Extension.run_after_tool([OnlyAfterRun], "bash", %{}, %{"o" => 1}, @ctx)
    end

    test "run_after_tools skips a module without the hook" do
      assert :continue = Extension.run_after_tools([OnlyAfterRun], [], @ctx)
    end

    test "run_after_run skips a module without the hook" do
      assert :accept = Extension.run_after_run([OnlyOnInput], %{}, @ctx)
    end

    test "after_tools callback typespec includes :terminate (extension.ex:55-56)" do
      {:ok, callbacks} = Code.Typespec.fetch_callbacks(Extension)
      {_, [spec | _]} = Enum.find(callbacks, fn {{name, arity}, _} -> {name, arity} == {:after_tools, 2} end)
      text = :after_tools |> Code.Typespec.spec_to_quoted(spec) |> Macro.to_string()

      assert text =~ ":terminate", "spec omits :terminate, which the machine handles: #{text}"
    end

    # on_yield/3 (moduledoc) is declared as on_yield/2 and never invoked anywhere: untestable dead code.
  end

  describe "harness registry (harness.ex:25-40,54-57,62-108)" do
    setup do
      previous = Application.get_env(:super_pi, :extra_harnesses)
      Application.put_env(:super_pi, :extra_harnesses, [ExtraHarness])

      on_exit(fn ->
        if previous == nil,
          do: Application.delete_env(:super_pi, :extra_harnesses),
          else: Application.put_env(:super_pi, :extra_harnesses, previous)
      end)

      :ok
    end

    test "resolve/1 finds an extra harness by id" do
      assert Harness.resolve("test-extra-harness") == ExtraHarness
    end

    test "harness?/1 recognises an extra harness id" do
      assert Harness.harness?("test-extra-harness")
    end

    test "resolve/1 accepts a plain (non-Elixir.-prefixed) module name string" do
      assert Harness.resolve("SuperPi.Harness.Planner") == SuperPi.Harness.Planner
    end

    test "Fast.agent_defaults/1 honours opts[:model] (harness/fast.ex:25-43)" do
      assert %{"model" => "custom-model"} = SuperPi.Harness.Fast.agent_defaults(model: "custom-model")
    end

    test "@callback extensions typespec admits {module, opts} tuples (harness.ex:20)" do
      {:ok, callbacks} = Code.Typespec.fetch_callbacks(Harness)
      {_, [spec | _]} = Enum.find(callbacks, fn {{name, arity}, _} -> {name, arity} == {:extensions, 1} end)
      text = :extensions |> Code.Typespec.spec_to_quoted(spec) |> Macro.to_string()

      assert Enum.any?(SuperPi.Harness.Autonomous.extensions(), &is_tuple/1)
      assert text =~ "{", "typespec is list(module()) but harnesses return tuples: #{text}"
    end
  end

  describe "Planner is read-only only by tool listing (harness/planner.ex:40-50)" do
    test "Planner.extensions/0 blocks bash" do
      assert {:block, _} = Extension.run_before_tool(Harness.Planner.extensions(), "bash", %{}, %{})
    end

    test "Planner.extensions/0 blocks write" do
      assert {:block, _} = Extension.run_before_tool(Harness.Planner.extensions(), "write", %{}, %{})
    end

    test "a machine run with Planner extensions does not execute a model-requested write" do
      conv = Storage.create_conversation!()
      test_pid = self()

      executor = fn name, _args, _ctx ->
        send(test_pid, {:executed, name})
        %{"output" => "ok", "details" => %{}}
      end

      {:ok, pid} =
        Machine.start_link(
          conversation_id: conv.id,
          extensions: Harness.Planner.extensions(),
          llm_responder: Faults.tool_then_text_responder("write", %{"path" => "/tmp/x", "content" => "y"}, "done"),
          tool_executor: executor
        )

      _ = Machine.submit(pid, "write a file", timeout: 3_000)

      refute_received {:executed, "write"}, "read-only Planner executed the write tool"
    end
  end

  describe "plugin resolution (plugins.ex:96-102,118-121)" do
    test "resolve/1 returns nil for a harness module (it exports id/0 but is not a plugin)" do
      assert Plugins.resolve(SuperPi.Harness.Default) == nil
    end

    # UNSURE: uniq_by keeps the first entry, so a bare module listed before its configured
    # {module, opts} twin silently discards the configuration. Intent may be "first wins".
    test "resolve_all/1 keeps the configured entry when a module is listed bare and with opts" do
      result = Plugins.resolve_all([Plugins.Todo, {Plugins.Todo, [some: :opt]}])

      assert {Plugins.Todo, [some: :opt]} in result,
             "configured opts dropped: #{inspect(result)}"
    end
  end
end
