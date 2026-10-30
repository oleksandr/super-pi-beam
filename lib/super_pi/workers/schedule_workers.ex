defmodule SuperPi.Workers.ScheduleTickWorker do
  @moduledoc """
  The one static `Oban.Plugins.Cron` entry (`{"* * * * *", ScheduleTickWorker}`). The cron
  leader inserts one tick job per minute for the whole cluster. The tick accounts for settled
  runs and enqueues a `SuperPi.Workers.ScheduleRunWorker` job for each due schedule
  (`SuperPi.Schedule.tick/1`).

  `max_attempts: 1`: a lost tick is repaired by the next one, which finds the same due rows.
  """
  use Oban.Worker, queue: :schedule_tick, max_attempts: 1

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    # The minute the job was scheduled for, not the time it ran: a late tick still fires the
    # right minute.
    minute = job.scheduled_at || DateTime.utc_now()
    _due = SuperPi.Schedule.tick(minute)
    :ok
  end
end

defmodule SuperPi.Workers.ScheduleRunWorker do
  @moduledoc """
  Starts one fire of a schedule. Unique on `[:schedule_id, :fire_at]` forever (`period:
  :infinity`), where `fire_at` is the scheduled minute (or a webhook's `Idempotency-Key`), so a
  duplicate tick or a webhook retry inserts nothing. `SuperPi.Schedule.run/2` then claims the
  fire with a conditional update, which makes an Oban retry or a `Lifeline` rescue harmless.

  The job ends when the run task is stored and its conversation machine is told. It does not
  wait for the turn, so it never holds a queue slot for the length of an LLM run. After the last
  attempt a failure counts against the schedule like a failed run.
  """
  use Oban.Worker,
    queue: :schedule_runs,
    max_attempts: 3,
    unique: [period: :infinity, keys: [:schedule_id, :fire_at]]

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: args} = job) do
    case SuperPi.Schedule.run(args) do
      {:ok, _} -> :ok
      {:error, reason} -> fail(job, reason)
    end
  rescue
    e -> fail(job, Exception.message(e))
  end

  defp fail(%Oban.Job{attempt: attempt, max_attempts: max, args: %{"schedule_id" => id}}, reason) do
    Logger.warning("[Schedule] run job of schedule #{id} failed (attempt #{attempt}/#{max}): #{inspect(reason)}")
    if attempt >= max, do: SuperPi.Schedule.record_failure(id, "could not start the run: #{inspect(reason)}")
    {:error, reason}
  end
end
