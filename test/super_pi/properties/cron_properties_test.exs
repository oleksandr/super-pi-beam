defmodule SuperPi.Properties.CronTest do
  @moduledoc """
  Properties of `SuperPi.Schedule.Cron.next_after/3` against a brute-force walk that tests every
  UTC minute with `Oban.Cron.Expression.now?/2` on the zone's wall clock.

  - It is strictly increasing: each result is after its argument, and chaining it never repeats
    or goes back.
  - It never skips a matching minute: the result is the first instant of the brute-force walk.
  - Across spring-forward and fall-back an expression that matches every hour yields neither a
    duplicate nor a gap, and a fixed-time expression fires once per local day.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias SuperPi.Schedule.Cron

  @tzdb Tzdata.TimeZoneDatabase

  # Zones with no change in 2026 as well as ones with changes. Exact comparison against the
  # brute-force walk holds where wall time and the clock agree (no change, or every-hour expressions).
  @fixed_zones ["Etc/UTC", "Asia/Kolkata", "Asia/Tokyo", "America/Phoenix"]
  @dst_zones ["America/New_York", "Europe/London", "Australia/Sydney", "Europe/Berlin"]

  defp subset(range, max) do
    gen(
      all(
        values <- uniq_list_of(integer(range), min_length: 1, max_length: max),
        do: Enum.sort(values)
      )
    )
  end

  defp field(values), do: Enum.join(values, ",")

  # Minutes and hours as lists, every day: a match is never more than a day away.
  defp expression(hours \\ :any) do
    gen all(
          minutes <- subset(0..59, 4),
          hour_values <- subset(0..23, 4)
        ) do
      hour_field = if hours == :every, do: "*", else: field(hour_values)
      "#{field(minutes)} #{hour_field} * * *"
    end
  end

  # Whole minutes between 2026-01-01 and 2026-12-31.
  defp instant do
    gen all(offset <- integer(0..(365 * 24 * 60))) do
      DateTime.add(~U[2026-01-01 00:00:00Z], offset * 60, :second)
    end
  end

  # An instant within two days of a 2026 transition of the New York, London, Sydney, Berlin zones.
  @transitions [
    ~U[2026-03-08 07:00:00Z],
    ~U[2026-11-01 06:00:00Z],
    ~U[2026-03-29 01:00:00Z],
    ~U[2026-10-25 01:00:00Z],
    ~U[2026-04-04 16:00:00Z],
    ~U[2026-10-03 16:00:00Z]
  ]

  defp near_transition do
    gen all(base <- member_of(@transitions), offset <- integer(-(48 * 60)..(48 * 60))) do
      DateTime.add(base, offset * 60, :second)
    end
  end

  defp brute_force(expr, zone, after_dt, limit_minutes) do
    {:ok, parsed} = Cron.parse(expr)
    start = %{DateTime.truncate(after_dt, :second) | second: 0}

    Enum.find_value(1..limit_minutes, fn i ->
      utc = DateTime.add(start, i * 60, :second)
      {:ok, local} = DateTime.shift_zone(utc, zone, @tzdb)
      if DateTime.compare(utc, after_dt) == :gt and Cron.matches?(parsed, local), do: utc
    end)
  end

  property "the result is strictly after its argument and chaining it is strictly increasing" do
    check all(
            expr <- expression(),
            zone <- member_of(@fixed_zones ++ @dst_zones),
            start <- instant(),
            max_runs: 80
          ) do
      {instants, _} =
        Enum.map_reduce(1..6, start, fn _, at ->
          {:ok, next} = Cron.next_after(expr, at, zone)
          assert DateTime.compare(next, at) == :gt
          assert next.second == 0
          {next, next}
        end)

      assert instants == Enum.uniq(instants)
      assert instants == Enum.sort(instants, DateTime)
    end
  end

  property "it never skips a matching minute (zones without a change, and every-hour expressions anywhere)" do
    check all(
            zone <- member_of(@fixed_zones),
            expr <- expression(),
            start <- instant(),
            max_runs: 60
          ) do
      {:ok, next} = Cron.next_after(expr, start, zone)
      assert next == brute_force(expr, zone, start, 24 * 60 + 5)
    end

    check all(
            zone <- member_of(@dst_zones),
            expr <- expression(:every),
            start <- one_of([instant(), near_transition()]),
            max_runs: 60
          ) do
      {:ok, next} = Cron.next_after(expr, start, zone)
      assert next == brute_force(expr, zone, start, 2 * 60 + 5)
    end
  end

  property "every-hour expressions across a change: no duplicate and no gap against the real clock" do
    check all(
            zone <- member_of(@dst_zones),
            minute <- integer(0..59),
            start <- near_transition(),
            max_runs: 60
          ) do
      expr = "#{minute} * * * *"

      {instants, _} =
        Enum.map_reduce(1..30, start, fn _, at ->
          {:ok, next} = Cron.next_after(expr, at, zone)
          {next, next}
        end)

      # Every instant of the walk matches the wall clock, and no matching instant lies between two
      # consecutive results.
      {:ok, parsed} = Cron.parse(expr)

      for utc <- instants do
        {:ok, local} = DateTime.shift_zone(utc, zone, @tzdb)
        assert Cron.matches?(parsed, local)
      end

      assert instants == Enum.uniq(instants)

      [first | _] = instants
      assert first == brute_force(expr, zone, start, 2 * 60 + 5)

      instants
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [a, b] -> assert b == brute_force(expr, zone, a, 2 * 60 + 5) end)
    end
  end

  property "a fixed-time daily expression fires once per local day, also across a change" do
    check all(
            zone <- member_of(@dst_zones),
            hour <- integer(0..23),
            minute <- integer(0..59),
            start <- near_transition(),
            max_runs: 60
          ) do
      expr = "#{minute} #{hour} * * *"

      {instants, _} =
        Enum.map_reduce(1..6, start, fn _, at ->
          {:ok, next} = Cron.next_after(expr, at, zone)
          {next, next}
        end)

      local_dates =
        Enum.map(instants, fn utc ->
          {:ok, local} = DateTime.shift_zone(utc, zone, @tzdb)
          DateTime.to_date(local)
        end)

      # One fire per local date: no duplicate on fall-back, and no skipped day on spring-forward.
      assert local_dates == Enum.uniq(local_dates)

      assert local_dates
             |> Enum.chunk_every(2, 1, :discard)
             |> Enum.all?(fn [a, b] -> Date.diff(b, a) == 1 end)
    end
  end
end
