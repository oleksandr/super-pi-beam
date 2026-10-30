defmodule SuperPi.Schedule.Cron do
  @moduledoc """
  Cron expressions with time zones.

  Parsing and field matching reuse `Oban.Cron.Expression`, which only answers "does this minute
  match". `next_after/3` adds the missing "when is the next one": a walk over local calendar
  days that skips a whole day when its month, day of month or weekday cannot match, then
  lists the matching local times of the days that remain. Granularity is one minute.

  Zone rules come from `Tzdata` (IANA data bundled with the package, no network at run time).

  ## Daylight saving time

  The result is always an instant (UTC, whole minute), strictly after the argument.

  - An expression that matches every hour (`*` in the hour field) follows the real clock. A
    local time that does not exist (spring forward) cannot fire, and a local time that occurs
    twice (fall back) fires twice. `0 * * * *` therefore fires once per real hour across
    both changes: no duplicate, no gap.
  - An expression with fixed hours (`30 2 * * *`) fires once per local day. When the local
    time falls in a spring-forward gap, the run happens at the first minute after the gap
    (as Vixie cron does) instead of being skipped. When it occurs twice, only the first
    occurrence fires.
  """

  alias Oban.Cron.Expression

  @tzdb Tzdata.TimeZoneDatabase
  # Eight years: enough for `0 0 29 2 *` across a skipped leap year (2100).
  @max_days 366 * 8

  @type expr :: Expression.t()

  @doc "Parses a five-field expression or an `@daily`-style alias. `@reboot` is rejected."
  @spec parse(String.t()) :: {:ok, expr()} | {:error, String.t()}
  def parse(input) when is_binary(input) do
    case Expression.parse(String.trim(input)) do
      {:ok, %Expression{reboot?: true}} -> {:error, "@reboot has no schedule"}
      {:ok, expr} -> {:ok, expr}
      {:error, exception} -> {:error, Exception.message(exception)}
    end
  end

  @doc "True when `zone` is a time zone of the bundled IANA database."
  @spec valid_timezone?(term()) :: boolean()
  def valid_timezone?(zone) when is_binary(zone), do: zone != "" and Tzdata.zone_exists?(zone)
  def valid_timezone?(_), do: false

  @doc """
  Does the local wall-clock minute of `datetime` match? `datetime` is read as it is, so pass it
  already shifted to the schedule's zone.
  """
  @spec matches?(expr(), DateTime.t() | NaiveDateTime.t()) :: boolean()
  def matches?(%Expression{} = expr, %NaiveDateTime{} = naive) do
    Expression.now?(expr, DateTime.from_naive!(naive, "Etc/UTC"))
  end

  def matches?(%Expression{} = expr, %DateTime{} = datetime), do: Expression.now?(expr, datetime)

  @doc """
  The first matching minute strictly after `after_dt`, as a UTC `DateTime`, for the expression
  read in `zone`. `{:error, :no_match}` when none exists within eight years (for example
  `0 0 30 2 *`) and `{:error, :invalid_timezone}` for an unknown zone.
  """
  @spec next_after(expr() | String.t(), DateTime.t(), String.t()) ::
          {:ok, DateTime.t()} | {:error, :no_match | :invalid_timezone | String.t()}
  def next_after(expr, after_dt, zone \\ "Etc/UTC")

  def next_after(expr, %DateTime{} = after_dt, zone) when is_binary(expr) do
    with {:ok, parsed} <- parse(expr), do: next_after(parsed, after_dt, zone)
  end

  def next_after(%Expression{} = expr, %DateTime{} = after_dt, zone) do
    if valid_timezone?(zone) do
      {:ok, local} = DateTime.shift_zone(after_dt, zone, @tzdb)
      # One day back: a fall-back repeat of late evening belongs to the previous local date.
      start = local |> DateTime.to_date() |> Date.add(-1)

      ctx = %{
        expr: expr,
        zone: zone,
        after: after_dt,
        hours: expr.hours |> Enum.sort(),
        minutes: expr.minutes |> Enum.sort(),
        every_hour?: MapSet.size(expr.hours) == 24
      }

      search(ctx, start, @max_days)
    else
      {:error, :invalid_timezone}
    end
  end

  defp search(_ctx, _date, 0), do: {:error, :no_match}

  defp search(ctx, date, left) do
    found =
      if day_matches?(ctx.expr, date) do
        date
        |> instants(ctx)
        |> Enum.filter(&(DateTime.compare(&1, ctx.after) == :gt))
        |> Enum.min(DateTime, fn -> nil end)
      end

    case found do
      nil -> search(ctx, Date.add(date, 1), left - 1)
      instant -> {:ok, instant}
    end
  end

  defp day_matches?(expr, date) do
    MapSet.member?(expr.months, date.month) and
      MapSet.member?(expr.days, date.day) and
      MapSet.member?(expr.weekdays, rem(Date.day_of_week(date), 7))
  end

  # All instants (UTC) of the day's matching local times.
  defp instants(date, ctx) do
    for h <- ctx.hours, m <- ctx.minutes, reduce: [] do
      acc ->
        naive = NaiveDateTime.new!(date, Time.new!(h, m, 0))
        resolve(DateTime.from_naive(naive, ctx.zone, @tzdb), ctx.every_hour?) ++ acc
    end
  end

  defp resolve({:ok, dt}, _every_hour?), do: [to_utc(dt)]
  defp resolve({:ambiguous, first, second}, true), do: [to_utc(first), to_utc(second)]
  defp resolve({:ambiguous, first, _second}, false), do: [to_utc(first)]
  defp resolve({:gap, _before, _after}, true), do: []
  defp resolve({:gap, _before, just_after}, false), do: [to_utc(just_after)]
  defp resolve({:error, _}, _every_hour?), do: []

  defp to_utc(dt) do
    {:ok, utc} = DateTime.shift_zone(dt, "Etc/UTC", @tzdb)
    %{DateTime.truncate(utc, :second) | second: 0}
  end
end
