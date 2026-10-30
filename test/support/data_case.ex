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
    on_exit(&SuperPi.DataCase.stop_leaked_machines/0)
    :ok
  end

  @doc """
  Conversation ids restart at 1 in every sandboxed test, so a machine that outlives its
  test (started from a Task or an unlinked caller) collides with the next test's machine.
  """
  def stop_leaked_machines do
    SuperPi.Registry
    |> Registry.select([{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.each(fn
      {{:conversation_machine, _id}, pid} -> Process.exit(pid, :kill)
      _ -> :ok
    end)
  end

  def setup_sandbox(tags) do
    repo = SuperPi.Repo.active_repo()
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(repo, shared: not tags[:async])
    if repo == SuperPi.Repo.SQLite, do: Ecto.Adapters.SQL.query!(repo, "PRAGMA foreign_keys = ON")
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ets.delete_all_objects(:super_pi_doc_cache)
    :ets.delete_all_objects(:super_pi_deferred_pending)
  end
end
