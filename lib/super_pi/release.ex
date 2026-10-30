defmodule SuperPi.Release do
  @moduledoc """
  Release tasks. Run them before the new version takes traffic:

      bin/super_pi eval "SuperPi.Release.migrate()"
      bin/super_pi eval "SuperPi.Release.rollback(20261029000001)"

  They start only the repo, so they work on a node that is not part of the cluster and do not
  start the application.
  """

  @app :super_pi

  @doc "Runs every pending migration on the configured repo."
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @doc "Rolls the configured repo back to `version` (inclusive)."
  def rollback(version) when is_integer(version) do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
    end

    :ok
  end

  defp repos, do: [SuperPi.Repo.active_repo()]

  defp load_app do
    Application.ensure_all_started(:ssl)
    Application.load(@app)
  end
end
