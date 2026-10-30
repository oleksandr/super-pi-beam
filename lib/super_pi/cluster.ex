defmodule SuperPi.Cluster do
  @moduledoc """
  The distributed BEAM cluster: nodes connected by `libcluster`, one shared PostgreSQL, one machine
  per conversation (`SuperPi.Conversation.Locator`).

  ## Configuration

  `config :super_pi, :cluster` is set from the environment (`config/runtime.exs`):

  | Variable | Meaning |
  |---|---|
  | `SUPER_PI_CLUSTER_STRATEGY` | `none` (default), `epmd`, `dnspoll`, `kubernetes_dns`, `gossip` |
  | `SUPER_PI_CLUSTER_HOSTS` | `epmd`: node names, comma separated (`super_pi@10.0.0.1,super_pi@10.0.0.2`) |
  | `SUPER_PI_CLUSTER_DNS_QUERY` | `dnspoll`: a name that resolves to every node (A records) |
  | `SUPER_PI_CLUSTER_NODE_BASENAME` | `dnspoll`, `kubernetes_dns`: the node name before `@` (default `super_pi`) |
  | `SUPER_PI_CLUSTER_K8S_SERVICE` | `kubernetes_dns`: the headless Service name |
  | `SUPER_PI_CLUSTER_POLL_MS` | polling interval for `dnspoll` and `kubernetes_dns` (default 5000) |
  | `SUPER_PI_CLUSTER_GOSSIP_SECRET` | `gossip`: shared secret for the multicast packets |
  | `SUPER_PI_CLUSTER_GOSSIP_PORT` | `gossip`: UDP port (default 45892) |

  Nodes also need a distribution name and a shared cookie (`RELEASE_NODE`, `RELEASE_COOKIE` with
  a release; `--name` and `--cookie` otherwise). A cluster requires PostgreSQL: with SQLite the
  application refuses to start.
  """

  @doc "The libcluster topologies from configuration. Empty when clustering is off."
  def topologies do
    case Application.get_env(:super_pi, :cluster, []) do
      cfg when is_list(cfg) -> Keyword.get(cfg, :topologies, [])
      _ -> []
    end
  end

  def strategy do
    case Application.get_env(:super_pi, :cluster, []) do
      cfg when is_list(cfg) -> Keyword.get(cfg, :strategy, :none)
      _ -> :none
    end
  end

  @doc "True when a cluster strategy is configured."
  def enabled?, do: topologies() != []

  @doc """
  Raises when the configuration cannot work: a cluster over SQLite. Called at application start.
  """
  def validate! do
    if enabled?() and SuperPi.Repo.active_repo() != SuperPi.Repo.Postgres do
      raise ArgumentError,
            "SUPER_PI_CLUSTER_STRATEGY=#{strategy()} needs PostgreSQL (SUPER_PI_STORAGE_BACKEND=postgres). " <>
              "SQLite is a single-node store."
    end

    :ok
  end

  @doc "Child specs for the application: the libcluster supervisor when a strategy is configured."
  def children do
    case topologies() do
      [] -> []
      topologies -> [{Cluster.Supervisor, [topologies, [name: SuperPi.ClusterSupervisor]]}]
    end
  end

  @doc """
  A summary of the cluster: this node, the connected nodes, the registry and supervisor members,
  and how many conversation machines run on each node.
  """
  def status do
    machines = SuperPi.Conversation.Locator.all()

    per_node =
      machines
      |> Enum.group_by(fn {_id, pid} -> node(pid) end)
      |> Map.new(fn {n, list} -> {n, length(list)} end)

    %{
      self: Node.self(),
      strategy: strategy(),
      connected_nodes: Node.list(),
      db_adapter: SuperPi.Repo.active_repo(),
      registry_members: members(SuperPi.ConversationRegistry),
      supervisor_members: members(SuperPi.MachineSupervisor),
      machines_per_node: per_node,
      machine_count: length(machines),
      machine_supervision: Application.get_env(:super_pi, :machine_supervision, :horde),
      accepting?: SuperPi.Drain.accepting?(),
      cluster_ready?: enabled?() and SuperPi.Repo.active_repo() == SuperPi.Repo.Postgres and Node.list() != []
    }
  end

  defp members(horde_name) do
    horde_name |> Horde.Cluster.members() |> Enum.map(fn {_name, node} -> node end) |> Enum.sort()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end
end
