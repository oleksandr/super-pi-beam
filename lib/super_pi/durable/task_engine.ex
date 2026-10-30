defmodule SuperPi.Durable.TaskEngine do
  @moduledoc """
  Durable task state machine scheduler (`REQ-FSM-01`..`REQ-FSM-05`, `REQ-OBAN-01`..`REQ-OBAN-02`).

  Uses `Fsmx` inside `Ecto.Multi` transactions to enforce valid state transitions:
  - `pending` -> `running` | `aborted` | `cancelled` | `orphaned` | `failed`
  - `running` -> `waiting` (`all_settled` | `fail_fast`) | `sleeping` (`sleep_until`) | `completing` | `completed` | `failed` | `aborted`
  - Open-time recovery (`reconcile_on_open!/1`): resets surviving `running` tasks to `pending`,
    increments `attempt`, cancels tasks with `abandon_on_restart: true`, and fails tasks that
    exceed `restart_limit` (default `5`).
  - Bottom-up subtree abort (`abort_task!/1`): marks the target task and its foreground-owned
    children `abort_requested: true`, settling children before completing the parent's abort.
  """

  import Ecto.Query
  alias Ecto.Multi
  alias SuperPi.Repo
  alias SuperPi.Durable.Storage
  alias SuperPi.Durable.Schemas.Task, as: TaskSchema
  alias SuperPi.Workers.GenerationWakeWorker

  @doc """
  Creates a new durable task in `"pending"` status.
  Rejects creation if `owner_task_id` is already `completing`, terminal, or `abort_requested`.
  """
  def create_task(conversation_id, kind, input \\ %{}, opts \\ []) do
    owner_task_id = Keyword.get(opts, :owner_task_id)
    restart_limit = Keyword.get(opts, :restart_limit, 5)
    abandon_on_restart = Keyword.get(opts, :abandon_on_restart, false)
    background = Keyword.get(opts, :background, false)
    phase = Keyword.get(opts, :phase, "init")

    Repo.transaction(fn ->
      case Repo.get(SuperPi.Durable.Schemas.Conversation, conversation_id) do
        nil ->
          Repo.active_repo().rollback(:conversation_not_found)

        _ ->
          :ok
      end

      if owner_task_id do
        case Repo.get(TaskSchema, owner_task_id) do
          nil ->
            Repo.active_repo().rollback(:invalid_owner)

          %TaskSchema{} = owner ->
            if TaskSchema.terminal?(owner) or owner.status == "completing" or owner.abort_requested do
              Repo.active_repo().rollback(:invalid_owner_state)
            end
        end
      end

      seq = Storage.next_seq!()

      %TaskSchema{}
      |> TaskSchema.changeset(%{
        conversation_id: conversation_id,
        owner_task_id: owner_task_id,
        kind: kind,
        status: "pending",
        phase: phase,
        input: input,
        state: %{"phase" => phase},
        restart_limit: restart_limit,
        abandon_on_restart: abandon_on_restart,
        background: background,
        created_seq: seq,
        updated_seq: seq
      })
      |> Repo.insert!()
    end)
  end

  @doc """
  Atomically transitions a task to `"running"`. The task row is locked for the
  read and the write, so two workers cannot both claim it: the loser gets
  `{:error, :already_running}`.
  """
  def start_task(task_id) do
    locked(task_id, fn
      %TaskSchema{status: "running"}, _seq -> Repo.active_repo().rollback(:already_running)
      task, seq -> transition!(task, "running", %{}, seq)
    end)
  end

  @doc """
  Checkpoints a running task to a new phase (`{phase: next_phase, ...}`).
  """
  def checkpoint_task(task_id, next_phase, new_state) when is_binary(next_phase) and is_map(new_state) do
    locked(task_id, fn
      %TaskSchema{status: status}, _seq when status != "running" ->
        Repo.active_repo().rollback({:invalid_status, status})

      task, seq ->
        transition!(
          task,
          "running",
          %{phase: next_phase, state: Map.put(new_state, "phase", next_phase)},
          seq
        )
    end)
  end

  @doc """
  Transitions a running task to `"waiting"` on `child_task_ids` with policy `"all_settled"` or `"fail_fast"`.

  The parent row is locked while the children are read and the parent is
  written. A child that settles concurrently takes the same lock in
  `reconcile_parent_after_child_settled!/2`, so it either sees `"waiting"` and
  wakes the parent, or commits first and this call sees it settled. No lost wakeup.
  """
  def wait_for_children(task_id, child_task_ids, wait_policy \\ "all_settled")
      when is_list(child_task_ids) and wait_policy in ["all_settled", "fail_fast"] do
    locked(task_id, fn parent, seq ->
      existing_children =
        if child_task_ids == [] do
          []
        else
          Repo.all(from t in TaskSchema, where: t.id in ^child_task_ids)
        end

      existing_ids = MapSet.new(existing_children, & &1.id)

      cond do
        child_task_ids != [] and not Enum.all?(child_task_ids, &MapSet.member?(existing_ids, &1)) ->
          Repo.active_repo().rollback(:unknown_child)

        child_task_ids == [] or Enum.all?(existing_children, &TaskSchema.terminal?/1) ->
          parent

        true ->
          transition!(
            parent,
            "waiting",
            %{wait_policy: wait_policy, waiting_on_task_ids: %{"ids" => child_task_ids}},
            seq
          )
      end
    end)
  end

  @doc """
  Transitions a running task to `"sleeping"` until `wake_at` (`DateTime.t()`) and schedules an
  `Oban` wake job (`REQ-OBAN-01`).
  """
  def sleep_until(task_id, %DateTime{} = wake_at, checkpoint_state \\ nil) do
    tx(fn seq ->
      task = lock_task(task_id) || raise Ecto.NoResultsError, queryable: TaskSchema

      params = %{
        sleep_until: wake_at,
        updated_seq: seq
      }

      params =
        if is_map(checkpoint_state) do
          phase = Map.get(checkpoint_state, "phase", task.phase)
          Map.merge(params, %{phase: phase, state: Map.put(checkpoint_state, "phase", phase)})
        else
          params
        end

      multi =
        Multi.new()
        |> Fsmx.transition_multi(task, :transition, "sleeping", params, state_field: :status)
        |> Oban.insert(
          :wake_job,
          GenerationWakeWorker.new(%{"task_id" => task.id, "wake_at" => DateTime.to_iso8601(wake_at)},
            scheduled_at: wake_at
          )
        )

      case Repo.transaction(multi) do
        {:ok, %{transition: updated}} ->
          updated

        {:error, _op, reason, _changes} ->
          Repo.active_repo().rollback(reason)
      end
    end)
  end

  @doc """
  Wakes a `"sleeping"` task back to `"pending"` when its deadline arrives.
  """
  def wake_sleeping_task(task_id) do
    locked(task_id, fn
      %TaskSchema{status: "sleeping"} = task, seq -> transition!(task, "pending", %{sleep_until: nil}, seq)
      _, _seq -> Repo.active_repo().rollback(:not_sleeping)
    end)
  end

  @doc """
  Completes a task with `result`.
  - If the task still has live foreground owned child tasks, transitions to `"completing"` and holds `result`.
  - Otherwise transitions to `"completed"` and reconciles any parent task waiting on it.
  """
  def complete_task(task_id, result \\ %{}) when is_map(result) do
    tx(fn seq ->
      task = lock_task(task_id) || raise Ecto.NoResultsError, queryable: TaskSchema

      if task.status in ["completed", "completing"] do
        task
      else
        live_children = list_live_owned_children(task.id)

        target_status = if live_children == [], do: "completed", else: "completing"

        case Fsmx.transition_changeset(task, target_status, %{result: result, updated_seq: seq}, state_field: :status)
             |> Repo.update() do
          {:ok, updated} ->
            if target_status == "completed" do
              reconcile_parent_after_child_settled!(updated, seq)
            end

            updated

          {:error, changeset} ->
            Repo.active_repo().rollback(changeset)
        end
      end
    end)
  end

  @doc """
  Fails a task with `error_map` and triggers `fail_fast` or `all_settled` reconciliation on its parent.
  """
  def fail_task(task_id, error_msg) when is_binary(error_msg) do
    fail_task(task_id, %{"error" => error_msg})
  end

  def fail_task(task_id, error_map) when is_map(error_map) do
    tx(fn seq ->
      task = lock_task(task_id) || raise Ecto.NoResultsError, queryable: TaskSchema

      if TaskSchema.terminal?(task) do
        task
      else
        live_children = list_live_owned_children(task.id)
        Enum.each(live_children, fn child ->
          abort_task!(child.id)
        end)

        case Fsmx.transition_changeset(task, "failed", %{result: error_map, updated_seq: seq}, state_field: :status)
             |> Repo.update() do
          {:ok, updated} ->
            reconcile_parent_after_child_settled!(updated, seq)
            updated

          {:error, changeset} ->
            Repo.active_repo().rollback(changeset)
        end
      end
    end)
  end

  @doc """
  Bottom-up subtree abort (`spec.md` §5.4):
  Marks the target task and all non-background owned descendants `abort_requested: true`.
  Settles leaf descendants as `"aborted"` first, then settles the parent task.
  """
  def abort_task!(task_id) do
    case Repo.get(TaskSchema, task_id) do
      nil ->
        {:error, :not_found}

      %TaskSchema{} ->
        {:ok, updated} =
          tx(fn seq -> abort_subtree_bottom_up!(task_id, seq) end)

        updated
    end
  end

  @doc """
  Open-time reconciliation (`spec.md` §2.5, §5.4, `REQ-FSM-04`, `REQ-FSM-05`):
  - Resets surviving `"running"` tasks for `conversation_id` to `"pending"` and increments `attempt`.
  - If `abandon_on_restart: true`, settles the task as `"cancelled"`.
  - If `attempt > restart_limit`, settles the task as `"failed"` with `"restart_limit_exceeded"`.
  """
  def reconcile_on_open!(conversation_id) do
    {:ok, reconciled} =
      tx(fn seq ->
        running_tasks =
          Repo.all(
            from t in TaskSchema,
              where: t.conversation_id == ^conversation_id and t.status == "running",
              order_by: [asc: t.id]
          )

        reconciled_running =
          Enum.map(running_tasks, fn %TaskSchema{} = task ->
            next_attempt = task.attempt + 1

            cond do
              task.abandon_on_restart ->
                {:ok, t} =
                  Fsmx.transition_changeset(task, "cancelled", %{
                    attempt: next_attempt,
                    result: %{"reason" => "abandoned_on_restart"},
                    updated_seq: seq
                  }, state_field: :status)
                  |> Repo.update()

                reconcile_parent_after_child_settled!(t, seq)
                t

              next_attempt > task.restart_limit ->
                {:ok, t} =
                  Fsmx.transition_changeset(task, "failed", %{
                    attempt: next_attempt,
                    result: %{"error" => "restart_limit_exceeded", "attempts" => next_attempt},
                    updated_seq: seq
                  }, state_field: :status)
                  |> Repo.update()

                reconcile_parent_after_child_settled!(t, seq)
                t

              true ->
                {:ok, t} =
                  Fsmx.transition_changeset(task, "pending", %{
                    attempt: next_attempt,
                    updated_seq: seq
                  }, state_field: :status)
                  |> Repo.update()

                t
            end
          end)

        waiting_tasks =
          Repo.all(
            from t in TaskSchema,
              where: t.conversation_id == ^conversation_id and t.status == "waiting",
              order_by: [asc: t.id]
          )

        Enum.each(waiting_tasks, fn %TaskSchema{} = parent ->
          child_ids = Map.get(parent.waiting_on_task_ids || %{}, "ids", [])
          children = if child_ids == [], do: [], else: Repo.all(from t in TaskSchema, where: t.id in ^child_ids)

          if child_ids == [] or Enum.all?(children, &TaskSchema.terminal?/1) do
            Fsmx.transition_changeset(parent, "running", %{updated_seq: seq}, state_field: :status)
            |> Repo.update!()
          end
        end)

        completing_tasks =
          Repo.all(
            from t in TaskSchema,
              where: t.conversation_id == ^conversation_id and t.status == "completing",
              order_by: [asc: t.id]
          )

        Enum.each(completing_tasks, fn %TaskSchema{} = parent ->
          live = list_live_owned_children(parent.id)

          if live == [] do
            target = if parent.abort_requested, do: "aborted", else: "completed"

            {:ok, t} =
              Fsmx.transition_changeset(parent, target, %{updated_seq: seq}, state_field: :status)
              |> Repo.update()

            reconcile_parent_after_child_settled!(t, seq)
          end
        end)

        reconciled_running
      end)

    reconciled
  end

  @doc """
  Performs an atomic `Fsmx` transition under a row lock (`REQ-FSM-01`, `REQ-FSM-02`).
  Returns `{:ok, task}`, `{:error, :not_found}` or `{:error, changeset}`.
  """
  def transition_task(task_id, target_status, extra_params \\ %{}) do
    locked(task_id, &transition!(&1, target_status, extra_params, &2))
  end

  # Every transaction takes the global seq row first, then task rows. `next_seq!/0`
  # holds that row until commit, so a fixed order (seq, then tasks) is what keeps
  # two transactions from deadlocking on PostgreSQL. `fun` receives the seq.
  defp tx(fun), do: Repo.transaction(fn -> fun.(Storage.next_seq!()) end, Storage.tx_opts())

  # Runs `fun` with the locked task and the transaction's seq. `fun` returns the
  # result or rolls back with a reason; a missing task is `{:error, :not_found}`.
  defp locked(task_id, fun) do
    tx(fn seq ->
      case lock_task(task_id) do
        nil -> Repo.active_repo().rollback(:not_found)
        task -> fun.(task, seq)
      end
    end)
  end

  # SQLite has no row locks; `Storage.tx_opts/0` serializes writers instead.
  defp lock_task(task_id) do
    if Storage.row_locks?() do
      Repo.one(from t in TaskSchema, where: t.id == ^task_id, lock: "FOR UPDATE")
    else
      Repo.get(TaskSchema, task_id)
    end
  end

  defp transition!(task, target_status, params, seq) do
    case task
         |> Fsmx.transition_changeset(target_status, Map.put(params, :updated_seq, seq), state_field: :status)
         |> Repo.update() do
      {:ok, updated} -> updated
      {:error, changeset} -> Repo.active_repo().rollback(changeset)
    end
  end

  defp abort_subtree_bottom_up!(task_id, seq) do
    task = lock_task(task_id) || raise Ecto.NoResultsError, queryable: TaskSchema

    if not task.abort_requested do
      task
      |> Ecto.Changeset.change(%{abort_requested: true})
      |> Repo.update!()
    end

    children =
      Repo.all(
        from c in TaskSchema,
          where: c.owner_task_id == ^task_id and c.background == false,
          order_by: [asc: c.id]
      )

    Enum.each(children, fn %TaskSchema{} = child ->
      if not TaskSchema.terminal?(child) do
        abort_subtree_bottom_up!(child.id, seq)
      end
    end)

    task = Repo.get!(TaskSchema, task_id)

    cond do
      TaskSchema.terminal?(task) ->
        task

      task.status == "completing" ->
        # A completing task keeps its held outcome with abort_requested: true once children settle
        {:ok, completed} =
          Fsmx.transition_changeset(task, "completed", %{
            abort_requested: true,
            updated_seq: seq
          }, state_field: :status)
          |> Repo.update()

        reconcile_parent_after_child_settled!(completed, seq)
        completed

      true ->
        {:ok, aborted} =
          Fsmx.transition_changeset(task, "aborted", %{
            abort_requested: true,
            result: %{"aborted" => true},
            updated_seq: seq
          }, state_field: :status)
          |> Repo.update()

        reconcile_parent_after_child_settled!(aborted, seq)
        aborted
    end
  end

  defp reconcile_parent_after_child_settled!(%TaskSchema{owner_task_id: nil}, _seq), do: :ok

  defp reconcile_parent_after_child_settled!(%TaskSchema{owner_task_id: parent_id} = child, seq) do
    # Same lock `wait_for_children/3` takes: see its doc.
    case lock_task(parent_id) do
      nil ->
        :ok

      %TaskSchema{status: "completing"} = parent ->
        if list_live_owned_children(parent.id) == [] do
          {:ok, done_parent} =
            Fsmx.transition_changeset(parent, "completed", %{updated_seq: seq}, state_field: :status)
            |> Repo.update()

          reconcile_parent_after_child_settled!(done_parent, seq)
        end

      %TaskSchema{status: "waiting", wait_policy: policy, waiting_on_task_ids: %{"ids" => watched_ids}} = parent ->
        cond do
          policy == "fail_fast" and child.status in ["failed", "aborted", "cancelled"] ->
            {:ok, woken} =
              Fsmx.transition_changeset(parent, "pending", %{
                updated_seq: seq,
                state: Map.put(parent.state, "failedChildId", child.id)
              }, state_field: :status)
              |> Repo.update()

            woken

          all_tasks_terminal?(watched_ids) ->
            {:ok, woken} =
              Fsmx.transition_changeset(parent, "pending", %{updated_seq: seq}, state_field: :status)
              |> Repo.update()

            woken

          true ->
            :ok
        end

      _ ->
        :ok
    end
  end

  defp list_live_owned_children(parent_task_id) do
    Repo.all(
      from t in TaskSchema,
        where:
          t.owner_task_id == ^parent_task_id and
            t.background == false and
            t.status in ["pending", "running", "waiting", "sleeping", "completing"]
    )
  end

  defp all_tasks_terminal?([]), do: true

  defp all_tasks_terminal?(task_ids) do
    tasks = Repo.all(from t in TaskSchema, where: t.id in ^task_ids)
    Enum.all?(tasks, &TaskSchema.terminal?/1)
  end
end
