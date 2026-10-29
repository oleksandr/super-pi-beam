defmodule SuperPi.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    SuperPi.Durable.Doc.ensure_ets!()
    SuperPi.Durable.DeferredFlusher.ensure_pending_ets!()

    children = [
      SuperPi.Repo.active_repo(),
      {Phoenix.PubSub, name: SuperPi.PubSub},
      {Registry, keys: :unique, name: SuperPi.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: SuperPi.FileLockSupervisor},
      {Task.Supervisor, name: SuperPi.ToolTaskSupervisor},
      SuperPi.Durable.DeferredFlusher,
      {Oban, Application.fetch_env!(:super_pi, Oban)}
    ]

    opts = [strategy: :rest_for_one, name: SuperPi.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
