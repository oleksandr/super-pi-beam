defmodule SuperPi.DataCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      alias SuperPi.Repo
      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import SuperPi.DataCase
    end
  end

  setup tags do
    SuperPi.DataCase.setup_sandbox(tags)

    on_exit(fn ->
      SuperPi.DataCase.await_quiet()
      SuperPi.DataCase.stop_leaked_machines()
    end)

    :ok
  end

  @doc """
  Waits, for at most about 3 seconds, until no tool task runs and every machine is idle.

  A machine or task that is killed in the middle of a write leaves the SQLite connection with a
  stale snapshot, and the next test's first write fails with "Database busy". One that outlives
  its sandbox owner commits outside the sandbox.
  """
  def await_quiet do
    await_tasks(100)
    await_idle(50)
  end

  defp await_tasks(0), do: :ok

  defp await_tasks(tries) do
    if Task.Supervisor.children(SuperPi.ToolTaskSupervisor) != [] do
      Process.sleep(20)
      await_tasks(tries - 1)
    end
  end

  defp await_idle(0), do: :ok

  defp await_idle(tries) do
    busy? =
      Enum.any?(SuperPi.Conversation.Locator.all(), fn {_id, pid} ->
        try do
          {state, _} = :gen_statem.call(pid, :get_state, 500)
          state != :idle
        catch
          :exit, _ -> false
        end
      end)

    if busy? do
      Process.sleep(20)
      await_idle(tries - 1)
    end
  end

  defp await_no_machines(0), do: :ok

  defp await_no_machines(tries) do
    if SuperPi.Conversation.Locator.all() == [] do
      :ok
    else
      Process.sleep(10)
      await_no_machines(tries - 1)
    end
  end

  @doc """
  Conversation ids restart at 1 in every sandboxed test, so a machine that outlives its
  test (started from a Task or an unlinked caller) collides with the next test's machine.
  """
  def stop_leaked_machines do
    # Terminate through the supervisors. Killing a supervised machine would make Horde restart it
    # (restart: :transient) after the test, when its sandbox connection is gone.
    Enum.each(SuperPi.Conversation.Locator.all(), fn {_id, pid} ->
      with {:error, :not_found} <-
             Horde.DynamicSupervisor.terminate_child(SuperPi.MachineSupervisor, pid),
           {:error, :not_found} <-
             DynamicSupervisor.terminate_child(SuperPi.LocalMachineSupervisor, pid) do
        Process.exit(pid, :kill)
      end
    end)
  end

  def setup_sandbox(tags) do
    stop_leaked_machines()
    await_no_machines(200)

    repo = SuperPi.Repo.active_repo()
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(repo, shared: not tags[:async])
    if repo == SuperPi.Repo.SQLite, do: Ecto.Adapters.SQL.query!(repo, "PRAGMA foreign_keys = ON")
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ets.delete_all_objects(:super_pi_doc_cache)
    :ets.delete_all_objects(:super_pi_deferred_pending)
  end
end
