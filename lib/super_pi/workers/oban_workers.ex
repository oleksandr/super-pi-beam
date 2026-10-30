defmodule SuperPi.Workers.GenerationWakeWorker do
  @moduledoc """
  Oban worker in `:generation_retry` queue that wakes sleeping `GenerationTask` records
  when their rate-limit backoff deadline (`sleep_until`) expires (`REQ-OBAN-01`).
  """
  use Oban.Worker, queue: :generation_retry, max_attempts: 5

  alias SuperPi.Durable.TaskEngine

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"task_id" => task_id} = args}) do
    task = SuperPi.Repo.get(SuperPi.Durable.Schemas.Task, task_id)
    job_wake_at = Map.get(args, "wake_at")

    cond do
      is_nil(task) ->
        :ok

      task.status != "sleeping" ->
        :ok

      is_binary(job_wake_at) and is_struct(task.sleep_until, DateTime) and
          DateTime.to_iso8601(task.sleep_until) != job_wake_at ->
        :ok

      true ->
        case TaskEngine.wake_sleeping_task(task_id) do
          {:ok, _task} -> :ok
          {:error, :not_sleeping} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end
end

defmodule SuperPi.Workers.CompactionWorker do
  @moduledoc """
  Oban worker in `:compaction` queue that runs background (`backgroundTokens`) and threshold
  context compaction tasks (`REQ-OBAN-02`).
  """
  use Oban.Worker,
    queue: :compaction,
    max_attempts: 3,
    unique: [period: 60, keys: [:conversation_id]]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"conversation_id" => conv_id} = args}) do
    opts =
      case Map.get(args, "keep_recent_tokens") do
        k when is_integer(k) -> [keep_recent_tokens: k]
        _ -> []
      end

    _ = SuperPi.Compaction.compact!(conv_id, :background, opts)

    Phoenix.PubSub.broadcast(
      SuperPi.PubSub,
      "conversation:#{conv_id}",
      {:compaction_job_triggered, args}
    )

    :ok
  end
end

defmodule SuperPi.Workers.VerificationWorker do
  @moduledoc """
  Oban worker in `:verification` queue for `after_run` (`runEndTask`) verification jobs.
  """
  use Oban.Worker, queue: :verification, max_attempts: 2

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"task_id" => task_id, "conversation_id" => conv_id}}) do
    Phoenix.PubSub.broadcast(
      SuperPi.PubSub,
      "conversation:#{conv_id}",
      {:verification_job_triggered, task_id}
    )

    :ok
  end
end

defmodule SuperPi.Workers.SubagentWorker do
  @moduledoc """
  Oban worker in the `:subagents` queue: runs one child conversation for `delegate_subagent`.

  The plugin creates the child conversation and its `pi.subagent` task, then enqueues this job. Any
  node can run it, so the queue limit (`config :super_pi, Oban, queues: [subagents: n]`) bounds the
  children of the whole cluster. The job:

  1. claims the task (`pending` to `running`). A task that was aborted while it waited is skipped.
  2. starts the child's machine and submits the prompt. The machine is unique in the cluster, so
     it may run on another node than this job.
  3. settles the task with the final text (`complete_task/2`) or the error (`fail_task/2`). That
     wakes the parent, whose machine is parked in `:awaiting_children`.

  `max_attempts: 1`: an LLM turn can have side effects (a worker edits files), so a retry could
  repeat them. A job lost with its node is not retried. The child's machine is restarted by Horde,
  resumes the turn from the durable state and settles the task itself (`settle/2`, called from
  the machine when the turn of a child conversation ends). If only the machine is lost, this job
  starts it again and waits for the task to settle.

  Test hook: `config :super_pi, :subagent_machine_opts` is merged into the child machine's
  options (an `llm_responder`, say). A job argument cannot carry a function.
  """
  use Oban.Worker, queue: :subagents, max_attempts: 1

  alias SuperPi.Conversation.{Locator, Machine}
  alias SuperPi.Durable.Schemas.Task, as: TaskSchema
  alias SuperPi.Durable.TaskEngine
  alias SuperPi.Event
  alias SuperPi.Plugins.Subagent

  require Logger

  @max_summary_chars 8_000
  @poll_ms 200

  # Oban kills a job that outlives the child's own deadline by this much (`:subagent_kill_slack_ms`).
  @impl Oban.Worker
  def timeout(%Oban.Job{args: %{"timeout_ms" => ms}}) when is_integer(ms),
    do: ms + Application.get_env(:super_pi, :subagent_kill_slack_ms, 30_000)

  def timeout(_job), do: :infinity

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"task_id" => task_id, "child_conversation_id" => child_id} = args
      }) do
    case TaskEngine.start_task(task_id) do
      {:ok, task} ->
        run(task, child_id, args)

      {:error, reason} ->
        # Aborted before it started, or claimed twice.
        Logger.info("[SubagentWorker] task #{task_id} not started: #{inspect(reason)}")
    end

    :ok
  end

  defp run(task, child_id, %{"role" => role, "prompt" => prompt, "timeout_ms" => timeout_ms}) do
    Event.publish(
      Event.subagent_started(task.conversation_id, task.owner_task_id, child_id, role, prompt)
    )

    outcome =
      try do
        run_turn(task, child_id, role, prompt, timeout_ms)
      rescue
        e -> {:error, "subagent crashed: #{Exception.message(e)}"}
      catch
        :exit, reason -> {:error, "subagent exited: #{inspect(reason)}"}
      end

    case outcome do
      :settled -> :ok
      {:timeout, message} -> settle_and_stop(task.id, child_id, {:error, message}, true)
      outcome -> settle_and_stop(task.id, child_id, outcome, false)
    end
  end

  defp run_turn(task, child_id, role, prompt, timeout_ms) do
    deadline = now() + timeout_ms
    opts = machine_opts(role)

    with {:ok, pid} <- start_machine(child_id, opts) do
      # A parent that was cancelled between the claim and now has aborted this task.
      if aborted?(task.id) do
        {:error, "aborted"}
      else
        case Machine.safe_submit(pid, prompt, timeout: max(deadline - now(), 1)) do
          {:ok, msg} ->
            {:ok, final_text(msg)}

          {:error, {:timeout, {:gen_statem, :call, _}}} ->
            {:timeout, "timed out after #{timeout_ms} ms"}

          # The machine is gone (its node stopped, say). Horde restarts it and the turn resumes.
          {:error, {_reason, {:gen_statem, :call, _}}} ->
            take_over(task.id, child_id, opts, deadline, timeout_ms)

          {:error, reason} ->
            {:error, format_reason(reason)}
        end
      end
    end
  end

  defp start_machine(child_id, opts) do
    case Locator.ensure_started(child_id, opts) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, "could not start the subagent: #{inspect(reason)}"}
    end
  end

  # The restarted machine resumes the pending turn and settles the task. Make sure one runs, then wait.
  defp take_over(task_id, child_id, opts, deadline, timeout_ms) do
    with {:ok, _pid} <- start_machine(child_id, opts) do
      await_settled(task_id, deadline, timeout_ms)
    end
  end

  defp await_settled(task_id, deadline, timeout_ms) do
    cond do
      settled?(task_id) ->
        :settled

      now() > deadline ->
        {:timeout, "timed out after #{timeout_ms} ms"}

      true ->
        Process.sleep(@poll_ms)
        await_settled(task_id, deadline, timeout_ms)
    end
  end

  # The outcome is recorded before the machine is cancelled: the machine's own settle of a cancelled
  # turn must not win and hide the reason.
  defp settle_and_stop(task_id, child_id, outcome, cancel?) do
    settle(task_id, outcome)

    case Locator.whereis(child_id) do
      pid when is_pid(pid) ->
        if cancel?, do: Machine.cancel(pid)
        stop_machine(pid, child_id)

      nil ->
        :ok
    end
  end

  defp stop_machine(pid, child_id) do
    try do
      :gen_statem.stop(pid)
    catch
      :exit, _ -> :ok
    end

    Locator.await_gone(child_id)
    :ok
  end

  @doc """
  Records how the child ended on its `pi.subagent` task, once. Called by this worker and by the
  child's machine when its turn ends, whichever comes first; the later call changes nothing. The
  event `subagent_finished` is published by the call that settles the task.
  """
  @spec settle(integer(), {:ok, String.t()} | {:error, term()}) :: :ok
  def settle(task_id, outcome) do
    with %TaskSchema{} = task <- TaskEngine.get_task(task_id),
         false <- TaskSchema.terminal?(task),
         {:ok, %TaskSchema{} = running} <- ensure_running(task) do
      settled =
        case outcome do
          {:ok, text} -> TaskEngine.complete_task(running.id, %{"summary" => truncate(text)})
          {:error, reason} -> TaskEngine.fail_task(running.id, format_reason(reason))
        end

      with {:ok, %TaskSchema{} = done} <- settled, do: publish_finished(done)
    end

    :ok
  end

  defp ensure_running(%TaskSchema{status: "pending", id: id}), do: TaskEngine.start_task(id)
  defp ensure_running(task), do: {:ok, task}

  defp publish_finished(%TaskSchema{} = task) do
    result = task.result || %{}

    Event.publish(
      Event.subagent_finished(
        task.conversation_id,
        task.owner_task_id,
        task.input["child_conversation_id"],
        task.status,
        result["summary"] || result["error"]
      )
    )
  end

  @doc "Machine options of a child with this role: its extensions, plus the test hook."
  @spec machine_opts(String.t()) :: keyword()
  def machine_opts(role),
    do:
      [extensions: Subagent.child_extensions(role)] ++
        Application.get_env(:super_pi, :subagent_machine_opts, [])

  @doc "The text of an assistant message."
  @spec final_text(term()) :: String.t()
  def final_text(%{"content" => blocks}) when is_list(blocks) do
    blocks
    |> Enum.map(&Map.get(&1, "text"))
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> String.trim()
  end

  def final_text(_), do: ""

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(:cancelled), do: "cancelled"
  defp format_reason(reason), do: inspect(reason)

  defp truncate(text) when byte_size(text) > @max_summary_chars,
    do: binary_part(text, 0, @max_summary_chars) <> "\n[truncated]"

  defp truncate(text), do: text

  defp aborted?(task_id),
    do: match?(%TaskSchema{abort_requested: true}, TaskEngine.get_task(task_id))

  defp settled?(task_id) do
    case TaskEngine.get_task(task_id) do
      %TaskSchema{} = task -> TaskSchema.terminal?(task)
      nil -> true
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
