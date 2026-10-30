defmodule SuperPi.Conversation.Locator do
  @moduledoc """
  Finds, or starts, the one machine of a conversation. The machine is unique in the whole
  cluster: its name is registered in `Horde.Registry`, so a request that lands on any node reaches
  the same process (a pid on another node works with `Machine.submit/3` and the rest of the API).

  ## Supervision

  `config :super_pi, machine_supervision:`

  - `:horde` (default). `Horde.DynamicSupervisor` places the machine on a node and restarts it on
    another node when its node stops. The machine starts in `:recovering`, finds the task that was
    running, and resumes it.
  - `:local`. The machine runs under the supervisor of the calling node and stays there. If the
    node stops, the name is released and the next request starts the machine on whichever node
    receives it (no automatic resume). Use it when a conversation must stay with the node that
    holds its `local` or `scratch` workspace.

  `restart: :transient` (default) restarts a machine that stops abnormally. `restart: :temporary`
  never restarts it; use that for short-lived helpers such as subagent children.

  A netsplit can briefly allow two machines for one conversation. Horde removes one when the
  nodes reconnect. Task rows carry the owner node, so the survivor does not reset a live task.
  """

  alias SuperPi.Conversation.Machine

  @registry SuperPi.ConversationRegistry

  def registry, do: @registry
  def key(conversation_id), do: {:conversation_machine, conversation_id}

  @doc "The machine pid for the conversation, on any node, or `nil`."
  @spec whereis(term()) :: pid() | nil
  def whereis(conversation_id) do
    case Horde.Registry.lookup(@registry, key(conversation_id)) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "All conversation ids that have a machine, with their pids (the whole cluster)."
  def all do
    @registry
    |> Horde.Registry.select([{{{:conversation_machine, :"$1"}, :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    # The registry removes an entry a moment after its process exits. Skip the dead local ones.
    |> Enum.filter(fn {_id, pid} -> node(pid) != node() or Process.alive?(pid) end)
  end

  @doc """
  Returns `{:ok, pid}` for the conversation's machine, starting it if there is none.
  `machine_opts` are the options of `Machine.start_link/1` (`:extensions`, test hooks).
  Options: `:restart` (default `:transient`), `:supervision` (default from config).
  """
  @spec ensure_started(term(), keyword(), keyword()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(conversation_id, machine_opts \\ [], opts \\ []) do
    case whereis(conversation_id) do
      pid when is_pid(pid) -> {:ok, pid}
      nil -> start(conversation_id, machine_opts, opts)
    end
  end

  defp start(conversation_id, machine_opts, opts, retries \\ 50) do
    restart = Keyword.get(opts, :restart, :transient)
    supervision = Keyword.get(opts, :supervision) || Application.get_env(:super_pi, :machine_supervision, :horde)

    spec = %{
      id: {:conversation, conversation_id},
      start: {Machine, :start_link, [Keyword.put(machine_opts, :conversation_id, conversation_id)]},
      restart: restart,
      type: :worker
    }

    result =
      case supervision do
        :local -> DynamicSupervisor.start_child(SuperPi.LocalMachineSupervisor, spec)
        _ -> Horde.DynamicSupervisor.start_child(SuperPi.MachineSupervisor, spec)
      end

    case result do
      {:ok, pid} -> {:ok, pid}
      {:ok, pid, _info} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      # The registry still holds the entry of a machine that has just exited. It removes the
      # entry a moment later, so try again.
      {:error, {:process_not_registered_via, _}} when retries > 0 ->
        Process.sleep(10)
        start(conversation_id, machine_opts, opts, retries - 1)

      other ->
        other
    end
  end

  @doc "Waits until the conversation has no registered machine. Returns `:ok` or `:timeout`."
  def await_gone(conversation_id, tries \\ 100) do
    cond do
      whereis(conversation_id) == nil -> :ok
      tries <= 0 -> :timeout
      true ->
        Process.sleep(5)
        await_gone(conversation_id, tries - 1)
    end
  end
end
