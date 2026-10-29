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
    :ok
  end

  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(SuperPi.Repo.SQLite, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ets.delete_all_objects(:super_pi_doc_cache)
    :ets.delete_all_objects(:super_pi_deferred_pending)
  end
end
