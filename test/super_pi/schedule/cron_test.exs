defmodule SuperPi.Schedule.CronTest do
  @moduledoc "Examples for `SuperPi.Schedule.Cron`, including the daylight saving cases."
  use ExUnit.Case, async: true

  alias SuperPi.Schedule.Cron

  defp next!(expr, after_iso, zone \\ "Etc/UTC") do
    {:ok, after_dt, 0} = DateTime.from_iso8601(after_iso)
    {:ok, next} = Cron.next_after(expr, after_dt, zone)
    DateTime.to_iso8601(next)
  end

  describe "parse/1" do
    test "accepts five fields and aliases, rejects the rest" do
      assert {:ok, _} = Cron.parse("*/5 * * * *")
      assert {:ok, _} = Cron.parse("@daily")
      assert {:error, _} = Cron.parse("@reboot")
      assert {:error, _} = Cron.parse("61 * * * *")
      assert {:error, _} = Cron.parse("* * *")
      assert {:error, _} = Cron.parse("0 0 31 4 *")
    end

    test "valid_timezone?/1" do
      assert Cron.valid_timezone?("Europe/London")
      assert Cron.valid_timezone?("Etc/UTC")
      refute Cron.valid_timezone?("Mars/Olympus")
      refute Cron.valid_timezone?("")
      refute Cron.valid_timezone?(nil)
    end
  end

  describe "next_after/3 in UTC" do
    test "is strictly after the argument, also when the argument matches" do
      assert next!("0 7 * * *", "2026-10-30T07:00:00Z") == "2026-10-31T07:00:00Z"
      assert next!("0 7 * * *", "2026-10-30T06:59:59Z") == "2026-10-30T07:00:00Z"
    end

    test "skips days that cannot match" do
      # 2026-10-30 is a Friday. The next Monday is 2 November.
      assert next!("30 9 * * 1", "2026-10-30T12:00:00Z") == "2026-11-02T09:30:00Z"
      assert next!("0 0 1 1 *", "2026-10-30T12:00:00Z") == "2027-01-01T00:00:00Z"
    end

    test "finds 29 February, also across the skipped leap year 2100" do
      assert next!("0 0 29 2 *", "2026-10-30T00:00:00Z") == "2028-02-29T00:00:00Z"
      assert next!("0 0 29 2 *", "2097-01-01T00:00:00Z") == "2104-02-29T00:00:00Z"
    end

    test "an expression that never matches ends the search" do
      # 29 February on a Monday: next in 2044, past the eight-year bound.
      {:ok, expr} = Cron.parse("0 0 29 2 1")
      assert {:error, :no_match} = Cron.next_after(expr, ~U[2026-01-01 00:00:00Z], "Etc/UTC")
    end

    test "an unknown zone is an error" do
      assert {:error, :invalid_timezone} = Cron.next_after("* * * * *", ~U[2026-01-01 00:00:00Z], "Mars/Olympus")
    end
  end

  describe "next_after/3 in a zone" do
    test "reads the expression in local time" do
      # London is UTC+1 in summer, UTC+0 in winter.
      assert next!("0 7 * * *", "2026-07-01T00:00:00Z", "Europe/London") == "2026-07-01T06:00:00Z"
      assert next!("0 7 * * *", "2026-12-01T00:00:00Z", "Europe/London") == "2026-12-01T07:00:00Z"
    end

    test "a fixed time inside the spring-forward gap fires right after the gap, once" do
      # New York, 2026-03-08: 02:00 EST jumps to 03:00 EDT (07:00Z). 02:30 does not exist.
      assert next!("30 2 * * *", "2026-03-07T12:00:00Z", "America/New_York") == "2026-03-08T07:00:00Z"
      # The next day fires at 02:30 EDT as usual.
      assert next!("30 2 * * *", "2026-03-08T07:00:00Z", "America/New_York") == "2026-03-09T06:30:00Z"
    end

    test "a fixed time that occurs twice on fall-back fires on the first occurrence only" do
      # New York, 2026-11-01: 02:00 EDT falls back to 01:00 EST. 01:30 happens at 05:30Z and 06:30Z.
      assert next!("30 1 * * *", "2026-10-31T12:00:00Z", "America/New_York") == "2026-11-01T05:30:00Z"
      assert next!("30 1 * * *", "2026-11-01T05:30:00Z", "America/New_York") == "2026-11-02T06:30:00Z"
    end

    test "an hourly expression follows the real clock across both changes" do
      assert hourly_gaps("2026-03-07T20:00:00Z", "America/New_York", 40) |> Enum.uniq() == [60]
      assert hourly_gaps("2026-10-31T20:00:00Z", "America/New_York", 40) |> Enum.uniq() == [60]
    end

    test "an every-30-minutes expression fires at every real half hour across fall-back" do
      assert chain("*/30 * * * *", "2026-11-01T04:00:00Z", "America/New_York", 8) ==
               ~w(2026-11-01T04:30:00Z 2026-11-01T05:00:00Z 2026-11-01T05:30:00Z 2026-11-01T06:00:00Z 2026-11-01T06:30:00Z 2026-11-01T07:00:00Z 2026-11-01T07:30:00Z 2026-11-01T08:00:00Z)
    end
  end

  defp chain(expr, start_iso, zone, n) do
    {:ok, start, 0} = DateTime.from_iso8601(start_iso)

    {list, _} =
      Enum.map_reduce(1..n, start, fn _, at ->
        {:ok, next} = Cron.next_after(expr, at, zone)
        {DateTime.to_iso8601(next), next}
      end)

    list
  end

  defp hourly_gaps(start_iso, zone, n) do
    {:ok, start, 0} = DateTime.from_iso8601(start_iso)

    {instants, _} =
      Enum.map_reduce(1..n, start, fn _, at ->
        {:ok, next} = Cron.next_after("0 * * * *", at, zone)
        {next, next}
      end)

    instants |> Enum.chunk_every(2, 1, :discard) |> Enum.map(fn [a, b] -> DateTime.diff(b, a, :minute) end)
  end
end
