defmodule SuperPi.CodeMode.Journal do
  @moduledoc """
  Deterministic Codemode Replay Journal (`Decision 07`, `Step 8`).

  When a Codemode script executes nested `execute_tool(call_index, tool_name, args)` calls inside a
  durable task (`task_id`), each completed nested call is persisted in a task-scoped document
  (`scope_kind: "task"`, `scope_id: task_id`, `kind: "pi.codemode.journal"`).

  If the BEAM node or worker crashes mid-script and `TaskEngine.reconcile_on_open!/1` restarts the
  Codemode task, `execute_journaled_tool/5` replays the exact recorded 3-channel result for already
  completed `call_index` steps without re-executing external side effects, and only runs live tool
  execution for unrecorded steps.
  """

  alias SuperPi.Durable.{Doc, Storage}

  @journal_doc_kind "pi.codemode.journal"

  @doc """
  Executes a nested tool call at deterministic step `call_index` within `task_id`.
  - If `(call_index, tool_name, args)` is already recorded in `pi.codemode.journal` for `task_id`,
    returns `{:replayed, cached_result}` without invoking `executor_fun`.
  - Otherwise invokes `executor_fun.(tool_name, args)`, persists the result in `pi.codemode.journal`,
    and returns `{:executed, fresh_result}`.
  """
  def execute_journaled_tool(task_id, call_index, tool_name, args, executor_fun)
      when is_integer(task_id) and is_integer(call_index) and is_binary(tool_name) and is_map(args) and
             is_function(executor_fun, 2) do
    journal = Doc.snapshot("task", task_id, @journal_doc_kind) || %{"steps" => %{}}
    steps = Map.get(journal, "steps", %{})
    step_key = Integer.to_string(call_index)

    case Map.get(steps, step_key) do
      %{"tool" => ^tool_name, "result" => cached_result} ->
        {:replayed, cached_result}

      _ ->
        fresh_result = executor_fun.(tool_name, args)

        updated_steps =
          Map.put(steps, step_key, %{
            "tool" => tool_name,
            "args" => args,
            "result" => fresh_result
          })

        Storage.commit(fn seq ->
          Doc.put_doc("task", task_id, @journal_doc_kind, %{"steps" => updated_steps}, seq)
        end)

        {:executed, fresh_result}
    end
  end

  @doc """
  Runs a sequence of Codemode step specifications `[{tool_name, args}, ...]` under `task_id` with
  automatic crash recovery replay. If `simulate_crash_at_index` is set, raises after that step so
  tests can verify deterministic replay on subsequent runs.
  """
  def run_script(task_id, steps_spec, executor_fun, opts \\ []) when is_list(steps_spec) do
    crash_at = Keyword.get(opts, :simulate_crash_at_index)

    steps_spec
    |> Enum.with_index(0)
    |> Enum.map(fn {{tool_name, args}, idx} ->
      {mode, result} = execute_journaled_tool(task_id, idx, tool_name, args, executor_fun)

      if crash_at == idx do
        raise RuntimeError, "simulated_codemode_crash_after_step_#{idx}"
      end

      %{index: idx, mode: mode, tool: tool_name, result: result}
    end)
  end
end
