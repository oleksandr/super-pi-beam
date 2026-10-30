defmodule SuperPi.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    SuperPi.Durable.Doc.ensure_ets!()
    SuperPi.Durable.DeferredFlusher.ensure_pending_ets!()
    SuperPi.Gateway.Router.ensure_session_cache!()
    SuperPi.MCP.Manager.create_tables()

    gateway_children =
      if Application.get_env(:super_pi, :start_gateway, false) do
        [{SuperPi.Gateway.Server, port: Application.get_env(:super_pi, :gateway_port, 4000)}]
      else
        []
      end

    children = [
      SuperPi.Repo.active_repo(),
      SuperPi.Repo.Migrator,
      {Phoenix.PubSub, name: SuperPi.PubSub},
      {Registry, keys: :unique, name: SuperPi.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: SuperPi.FileLockSupervisor},
      {DynamicSupervisor, strategy: :one_for_one, name: SuperPi.MachineSupervisor},
      {DynamicSupervisor, strategy: :one_for_one, name: SuperPi.MCPClientSupervisor},
      {Task.Supervisor, name: SuperPi.ToolTaskSupervisor},
      SuperPi.Durable.DeferredFlusher,
      {Oban, Application.fetch_env!(:super_pi, Oban)}
    ] ++ gateway_children

    opts = [strategy: :rest_for_one, name: SuperPi.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
