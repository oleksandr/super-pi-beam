defmodule SuperPi.Properties.PermissionsModeTest do
  @moduledoc """
  Properties of the remote mode limit (`Permissions.remote_mode/1`,
  `Permissions.sanitize_remote_agent/1`).
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias SuperPi.Plugins.Permissions

  @modes ["plan", "accept-edits", "auto"]
  @rank %{"plan" => 0, "accept-edits" => 1, "auto" => 2}
  @forbidden [
    "dangerouslySkipPermissions",
    "settingsOverride",
    "workspacePaths",
    "appDataDir",
    "globalConfigDir"
  ]

  setup do
    saved = Application.fetch_env(:super_pi, :permissions)

    on_exit(fn ->
      case saved do
        {:ok, v} -> Application.put_env(:super_pi, :permissions, v)
        :error -> Application.delete_env(:super_pi, :permissions)
      end
    end)

    :ok
  end

  # Requested value: junk, valid modes, and valid modes with odd case or spacing.
  defp requested do
    one_of([
      constant(nil),
      integer(),
      string(:printable),
      member_of(@modes),
      map({member_of(@modes), member_of([:upcase, :pad, :both, :none])}, fn
        {m, :upcase} -> String.upcase(m)
        {m, :pad} -> "  " <> m <> " "
        {m, :both} -> " " <> String.upcase(m) <> "\n"
        {m, :none} -> m
      end)
    ])
  end

  # Default and ceiling. The ceiling may be below the default; the code must still cap the result.
  defp limits, do: {member_of(@modes), member_of(@modes)}

  defp configure({default, ceiling}) do
    Application.put_env(:super_pi, :permissions,
      remote_default_mode: default,
      remote_max_mode: ceiling
    )
  end

  property "the result is a valid mode at or below the ceiling" do
    check all(req <- requested(), limits <- limits(), max_runs: 200) do
      configure(limits)
      {_default, ceiling} = limits
      mode = Permissions.remote_mode(req)

      assert mode in @modes
      assert @rank[mode] <= @rank[ceiling]
    end
  end

  property "a valid request within the ceiling comes back unchanged" do
    check all(mode <- member_of(@modes), limits <- limits(), max_runs: 100) do
      configure(limits)
      {_default, ceiling} = limits

      if @rank[mode] <= @rank[ceiling] do
        assert Permissions.remote_mode(mode) == mode
      end
    end
  end

  property "remote_mode is idempotent" do
    check all(req <- requested(), limits <- limits(), max_runs: 200) do
      configure(limits)
      once = Permissions.remote_mode(req)
      assert Permissions.remote_mode(once) == once
    end
  end

  property "raising the ceiling never lowers the result" do
    check all(
            req <- requested(),
            default <- member_of(@modes),
            low <- member_of(@modes),
            high <- member_of(@modes),
            max_runs: 200
          ) do
      {low, high} = if @rank[low] <= @rank[high], do: {low, high}, else: {high, low}

      Application.put_env(:super_pi, :permissions,
        remote_default_mode: default,
        remote_max_mode: low
      )

      at_low = Permissions.remote_mode(req)

      Application.put_env(:super_pi, :permissions,
        remote_default_mode: default,
        remote_max_mode: high
      )

      at_high = Permissions.remote_mode(req)

      assert @rank[at_high] >= @rank[at_low]
    end
  end

  property "sanitize removes forbidden keys, limits the mode, and keeps every other key" do
    check all(
            others <-
              map_of(
                string(:alphanumeric, min_length: 1),
                one_of([integer(), string(:printable), boolean()]),
                max_length: 6
              ),
            forbidden <-
              list_of(
                {member_of(@forbidden),
                 one_of([boolean(), string(:printable), constant(%{"x" => 1}), constant(["/"])])}
              ),
            mode <- one_of([constant(:absent), requested()]),
            limits <- limits(),
            max_runs: 200
          ) do
      configure(limits)
      {_default, ceiling} = limits

      others = Map.drop(others, ["executionMode" | @forbidden])
      agent = Map.merge(others, Map.new(forbidden))
      agent = if mode == :absent, do: agent, else: Map.put(agent, "executionMode", mode)

      out = Permissions.sanitize_remote_agent(agent)

      for key <- @forbidden, do: refute(Map.has_key?(out, key))
      assert Map.take(out, Map.keys(others)) == others

      case Map.fetch(out, "executionMode") do
        {:ok, m} -> assert m in @modes and @rank[m] <= @rank[ceiling]
        :error -> assert mode == :absent
      end

      assert Permissions.sanitize_remote_agent(out) == out
    end
  end
end
