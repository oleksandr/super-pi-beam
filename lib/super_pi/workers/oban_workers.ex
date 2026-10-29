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
  Oban worker in `:subagents` queue for child conversation execution.
  """
  use Oban.Worker, queue: :subagents, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"child_conversation_id" => child_id}}) do
    Phoenix.PubSub.broadcast(
      SuperPi.PubSub,
      "conversation:#{child_id}",
      {:subagent_job_triggered, child_id}
    )

    :ok
  end
end
