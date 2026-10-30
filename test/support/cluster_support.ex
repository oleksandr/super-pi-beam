defmodule SuperPi.ClusterSupport do
  @moduledoc """
  Starts peer nodes that run the whole application against the shared PostgreSQL, and the small
  helpers that run on them. Used by `test/super_pi/cluster_test.exs`.

  The test node is only a controller: it stops its own copy of the application, so it is not a
  member of the cluster and does not host conversations. All database work goes through the peers.
  """

  @cookie ~c"super_pi_cluster_test"

  @doc """
  The test VM must be a hidden distributed node: a hidden node can call the peers without
  joining the cluster (Horde and `Node.list/0` ignore hidden connections). Start it with

      elixir --erl "-hidden" --name sp_ctl@127.0.0.1 --cookie super_pi_cluster_test -S mix test --only cluster
  """
  def ensure_distributed do
    unless Node.alive?() do
      raise "the cluster tests need a distributed test VM: " <>
              ~s(elixir --erl "-hidden" --name sp_ctl@127.0.0.1 --cookie super_pi_cluster_test -S mix test --only cluster ...)
    end

    :ok
  end

  @doc "Stops the application on the test node. It is a controller, not a member."
  def become_controller do
    Application.stop(:super_pi)
    :ok
  end

  @doc """
  Starts `count` peers with the application running, and connects them. Returns
  `[%{name: atom, node: node, peer: pid}]`. `env` overrides application settings on every peer.
  """
  def start_peers(count, env \\ []) do
    base_env = peer_env(env)

    peers =
      for i <- 1..count do
        name = String.to_atom("sp#{i}_#{System.unique_integer([:positive])}")

        {:ok, peer, node} =
          :peer.start_link(%{
            name: name,
            host: ~c"127.0.0.1",
            longnames: true,
            args: [~c"-setcookie", @cookie] ++ Enum.flat_map(:code.get_path(), &[~c"-pa", &1])
          })

        :ok = :erpc.call(node, Application, :put_all_env, [base_env])
        {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:super_pi], 120_000)
        :ok = :erpc.call(node, Logger, :configure, [[level: :warning]])
        %{name: name, node: node, peer: peer}
      end

    # Connect them to each other. Horde and the process groups follow node events.
    nodes = Enum.map(peers, & &1.node)

    for a <- nodes, b <- nodes, a != b do
      :erpc.call(a, Node, :connect, [b])
    end

    peers
  end

  def stop_peers(peers) do
    for %{peer: peer} <- peers do
      try do
        :peer.stop(peer)
      catch
        _, _ -> :ok
      end
    end

    :ok
  end

  # The settings of this node, with the pool changed from the test sandbox to the real pool.
  defp peer_env(extra) do
    super_pi =
      :super_pi
      |> Application.get_all_env()
      |> Keyword.put(:mcp_clients, false)
      |> Keyword.put(:auto_migrate, false)
      |> Keyword.put(:deferred_flush_interval_ms, 1_000)
      |> Keyword.put(:drain_on_stop, false)
      |> Keyword.put(:storage_backend, :postgres)
      |> Keyword.put(:ecto_repos, [SuperPi.Repo.Postgres])
      |> Keyword.update(SuperPi.Repo.Postgres, [], &Keyword.delete(&1, :pool))
      |> Keyword.update(Oban, [], &Keyword.merge(&1, engine: Oban.Engines.Basic, repo: SuperPi.Repo.Postgres, testing: :manual))

    [super_pi: Keyword.merge(super_pi, extra), opentelemetry: Application.get_all_env(:opentelemetry)]
  end

  # --- Helpers that run on a peer ---

  @doc "Spawns a process that asks a question and sends `{:answer, result}` to `reply_to`."
  def start_asker(conversation_id, reply_to) do
    spawn(fn ->
      result = SuperPi.UI.Broker.ask(conversation_id, %{"kind" => "questionnaire", "questions" => [%{"question" => "q"}]}, 15_000)
      send(reply_to, {:answer, result})
    end)
  end

  @doc "Spawns a responder: registers for the conversation and forwards each `ui_request` event to `report_to`."
  def start_responder(conversation_id, report_to) do
    spawn(fn ->
      Phoenix.PubSub.subscribe(SuperPi.PubSub, "conversation:#{conversation_id}")
      SuperPi.UI.Broker.register_responder(conversation_id)
      send(report_to, {:responder_ready, node()})
      forward(report_to)
    end)
  end

  defp forward(report_to) do
    receive do
      {:conversation_event, _, %{"type" => "ui_request"} = event} ->
        send(report_to, {:ui_request, node(), event})
        forward(report_to)

      _ ->
        forward(report_to)
    end
  end

  @doc "Starts a turn on the conversation's machine without waiting; sends `{:turn, result}` to `reply_to`."
  def submit_async(conversation_id, text, reply_to) do
    spawn(fn ->
      {:ok, pid} = SuperPi.Conversation.Locator.ensure_started(conversation_id, extensions: [])
      send(reply_to, {:turn, SuperPi.Conversation.Machine.submit(pid, text, timeout: 60_000)})
    end)
  end

  @doc "Creates a conversation with a unique tool-less agent config and returns its id."
  def create_conversation(agent \\ %{"model" => "m"}) do
    SuperPi.Durable.Storage.create_conversation!(agent: agent).id
  end

  @doc "Adds one to the conversation's input-token count inside one commit (a read-modify-write)."
  def add_usage(conversation_id) do
    SuperPi.Durable.Storage.commit(fn seq ->
      current = SuperPi.Durable.Doc.snapshot_for_update("conversation", conversation_id, "pi.usage") || %{}
      next = %{"inputTokens" => Map.get(current, "inputTokens", 0) + 1}
      SuperPi.Durable.Doc.put_doc("conversation", conversation_id, "pi.usage", next, seq)
    end)
  end

  @doc "The status of the newest `pi.generation` task of the conversation."
  def generation_status(conversation_id) do
    import Ecto.Query

    SuperPi.Repo.one(
      from t in SuperPi.Durable.Schemas.Task,
        where: t.conversation_id == ^conversation_id and t.kind == "pi.generation",
        order_by: [desc: t.id],
        limit: 1,
        select: t.status
    )
  end

  @doc "Creates a task of the conversation that node `owner` runs, and returns it."
  def create_running_task(conversation_id, owner) do
    import Ecto.Query
    {:ok, task} = SuperPi.Durable.TaskEngine.create_task(conversation_id, "pi.generation", %{})
    {:ok, running} = SuperPi.Durable.TaskEngine.start_task(task.id)
    SuperPi.Repo.update_all(from(t in SuperPi.Durable.Schemas.Task, where: t.id == ^running.id), set: [owner_node: Atom.to_string(owner)])
    running
  end

  @doc """
  Stops the conversation's machine for good (no restart). The supervisor call has to run on the
  node that hosts the machine: `Horde.DynamicSupervisor.terminate_child/2` from another node
  returns `:ok` and leaves a remote machine running.
  """
  def stop_machine(conversation_id) do
    case SuperPi.Conversation.Locator.whereis(conversation_id) do
      pid when is_pid(pid) -> :erpc.call(node(pid), __MODULE__, :terminate_local, [pid])
      nil -> :ok
    end
  end

  @doc false
  def terminate_local(pid), do: Horde.DynamicSupervisor.terminate_child(SuperPi.MachineSupervisor, pid)

  @doc "The task as stored."
  def get_task(task_id), do: SuperPi.Repo.get(SuperPi.Durable.Schemas.Task, task_id)

  @doc "The messages of the conversation's active context."
  def messages(conversation_id), do: SuperPi.Durable.Context.derive(conversation_id).messages

  @doc "Reads a conversation document."
  def doc(conversation_id, kind), do: SuperPi.Durable.Doc.snapshot("conversation", conversation_id, kind)

  @doc "Deletes test data of the conversations."
  def cleanup(conversation_ids) do
    import Ecto.Query
    SuperPi.Repo.delete_all(from t in SuperPi.Durable.Schemas.Task, where: t.conversation_id in ^conversation_ids)
    SuperPi.Repo.delete_all(from c in SuperPi.Durable.Schemas.Conversation, where: c.id in ^conversation_ids)
    :ok
  end
end
