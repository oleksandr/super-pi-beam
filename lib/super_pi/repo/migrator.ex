defmodule SuperPi.Repo.Migrator do
  @moduledoc """
  Applies pending migrations when the application starts, so a fresh checkout
  works without a separate `mix ecto.migrate` step.

  Start it right after the repo. It returns `:ignore` once the migrations have run,
  so it never stays in the supervision tree. Disable it with
  `config :super_pi, auto_migrate: false`. For PostgreSQL the database must already
  exist; only the schema is created.
  """

  require Logger

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}
  end

  def start_link(_opts) do
    if Application.get_env(:super_pi, :auto_migrate, true), do: migrate!()
    :ignore
  end

  @doc "Runs every pending migration on the active repo and returns the versions applied."
  def migrate! do
    versions = Ecto.Migrator.run(SuperPi.Repo.active_repo(), :up, all: true, log: false)

    if versions != [] do
      Logger.info("Applied #{length(versions)} database migration(s)")
    end

    versions
  end
end
