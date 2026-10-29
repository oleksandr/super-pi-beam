defmodule SuperPi.Cluster do
  @moduledoc """
  Multi-Node Distributed Cluster Topology & `Horde` Conversation Routing (`Step 11`).

  When running on PostgreSQL (`SUPER_PI_STORAGE_BACKEND=postgres`), multiple BEAM nodes form a cluster
  via `libcluster` and register conversation state machines in `Horde.Registry` and
  `Horde.DynamicSupervisor`, providing transparent cross-node conversation handoff and automatic
  failover with `TaskEngine.reconcile_on_open!/1`.
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
