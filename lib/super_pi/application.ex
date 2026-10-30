defmodule SuperPi.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    SuperPi.Cluster.validate!()
    SuperPi.Durable.Doc.ensure_ets!()
    SuperPi.Durable.DeferredFlusher.ensure_pending_ets!()
    SuperPi.MCP.Manager.create_tables()

    gateway_children =
      if Application.get_env(:super_pi, :start_gateway, false) do
        [
          {SuperPi.Gateway.Server,
           port: Application.get_env(:super_pi, :gateway_port, 4000), ip: Application.get_env(:super_pi, :gateway_ip, {127, 0, 0, 1})}
        ]
      else
        []
      end

    children = [
      SuperPi.Repo.active_repo(),
      SuperPi.Repo.Migrator,
      {Phoenix.PubSub, name: SuperPi.PubSub},
      # Process groups across the connected nodes (UI broker).
      SuperPi.UI.Broker,
      SuperPi.UI.Pending,
      SuperPi.Durable.DocCache,
      {Registry, keys: :unique, name: SuperPi.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: SuperPi.FileLockSupervisor},
      # One machine per conversation in the whole cluster (see SuperPi.Conversation.Locator).
      {Horde.Registry, name: SuperPi.ConversationRegistry, keys: :unique, members: :auto},
      # The restart budget is shared by every conversation, so it is generous: one conversation that
      # crashes at start must not exhaust it for the others.
      {Horde.DynamicSupervisor, name: SuperPi.MachineSupervisor, strategy: :one_for_one, members: :auto, max_restarts: 100, max_seconds: 5},
      {DynamicSupervisor, strategy: :one_for_one, name: SuperPi.LocalMachineSupervisor}
    ] ++
      SuperPi.Cluster.children() ++
      [
      {DynamicSupervisor, strategy: :one_for_one, name: SuperPi.MCPClientSupervisor},
      {Task.Supervisor, name: SuperPi.ToolTaskSupervisor},
      {TelemetryMetricsPrometheus.Core, name: SuperPi.Telemetry.reporter_name(), metrics: SuperPi.Telemetry.metrics()},
      SuperPi.Durable.DeferredFlusher,
      {Oban, Application.fetch_env!(:super_pi, Oban)}
    ] ++ gateway_children

    opts = [strategy: :rest_for_one, name: SuperPi.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # SIGTERM stops the application. Before the supervision tree goes down, stop taking new work and
  # let the running turns finish (see SuperPi.Drain).
  @impl true
  def prep_stop(state) do
    if Application.get_env(:super_pi, :drain_on_stop, true), do: SuperPi.Drain.drain()
    state
  end
end
