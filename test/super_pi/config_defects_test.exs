defmodule SuperPi.ConfigDefectsTest do
  @moduledoc """
  Regression tests that reproduce configuration defects found in the code review
  (see vault note "20 - Codebase Review Findings"). Every test is expected to
  FAIL on the current code and pass once the matching finding is fixed.

  Run only these:  mix test --only known_bug
  Skip these:      mix test --exclude known_bug
  """
  use ExUnit.Case, async: false

  @moduletag :known_bug

  @config_dir Path.expand("../../config", __DIR__)

  defp read_config(file, env) do
    Config.Reader.read!(Path.join(@config_dir, file), env: env, target: :host)
  end

  defp with_env(vars, fun) do
    previous = Map.new(vars, fn {k, _} -> {k, System.get_env(k)} end)
    Enum.each(vars, fn {k, v} -> System.put_env(k, v) end)

    try do
      fun.()
    after
      Enum.each(previous, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end
  end

  test "config/config.exs loads for MIX_ENV=prod (config/prod.exs is missing)" do
    assert is_list(read_config("config.exs", :prod))
  end

  test "SUPER_PI_STORAGE_BACKEND=postgres makes ecto tasks target the Postgres repo" do
    config =
      with_env(
        [
          {"SUPER_PI_STORAGE_BACKEND", "postgres"},
          {"DATABASE_URL", "ecto://u:p@localhost/db"}
        ],
        fn -> read_config("runtime.exs", :dev) end
      )

    assert get_in(config, [:super_pi, :storage_backend]) == :postgres

    assert get_in(config, [:super_pi, :ecto_repos]) == [SuperPi.Repo.Postgres],
           "ecto_repos still lists only SQLite, so mix ecto.migrate never migrates Postgres"
  end

  test "postgres backend refuses to start without DATABASE_URL instead of using a hardcoded fallback" do
    with_env([{"SUPER_PI_STORAGE_BACKEND", "postgres"}], fn ->
      previous = System.get_env("DATABASE_URL")
      System.delete_env("DATABASE_URL")

      try do
        result =
          try do
            {:ok, read_config("runtime.exs", :prod)}
          rescue
            _ -> :raised
          end

        assert result == :raised,
               "runtime.exs silently falls back to postgres:postgres@localhost"
      after
        if previous, do: System.put_env("DATABASE_URL", previous)
      end
    end)
  end

  test "Oban prunes finished jobs and rescues orphaned executing jobs" do
    plugins =
      :super_pi
      |> Application.fetch_env!(Oban)
      |> Keyword.get(:plugins, [])
      |> Enum.map(fn
        {mod, _opts} -> mod
        mod -> mod
      end)

    assert Oban.Plugins.Pruner in plugins, "oban_jobs grows without bound"
    assert Oban.Plugins.Lifeline in plugins, "jobs executing during a crash stay executing forever"
  end
end
