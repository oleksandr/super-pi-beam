defmodule SuperPi.Cluster do
  @moduledoc """
  Runtime topology inspector.

  Multi-node operation is not implemented. The application starts a local `Registry` and a local
  `DynamicSupervisor`, and no `libcluster` or `Horde` process. `status/0` therefore reports
  `cluster_ready?: false` unless such a process is supervised. PostgreSQL storage
  (`SUPER_PI_STORAGE_BACKEND=postgres`) works for a single node. Multi-node work is tracked as
  Task 36 on the project board.
  """

  @doc """
  Returns the current cluster node topology summary.
  """
  def status do
    children =
      case Process.whereis(SuperPi.Supervisor) do
        nil -> []
        _ -> Supervisor.which_children(SuperPi.Supervisor) |> Enum.map(&elem(&1, 0))
      end

    cluster_supervised? =
      Enum.any?(children, fn id -> inspect(id) =~ ~r/Horde|Cluster\.Supervisor/ end)

    %{
      self: Node.self(),
      connected_nodes: Node.list(),
      db_adapter: SuperPi.Repo.active_repo(),
      cluster_ready?: SuperPi.Repo.active_repo() == SuperPi.Repo.Postgres and cluster_supervised?
    }
  end
end
