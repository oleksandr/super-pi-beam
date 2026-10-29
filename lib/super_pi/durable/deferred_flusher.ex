defmodule SuperPi.Durable.DeferredFlusher do
  @moduledoc """
  Implements `pi-durable` deferred commit batching (`REQ-DUR-04`, `REQ-DUR-05`).

  Streaming partial tokens and tool stdout commit to `:ets` every `100ms` so UI watchers see
  instant updates, and flush to SQLite/PostgreSQL lazily within `1000ms` or piggyback on the
  next immediate commit.
  """
  use GenServer

  alias SuperPi.Durable.{Doc, Storage}

  @pending_ets :super_pi_deferred_pending
  @default_flush_interval_ms 1_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Stages a deferred document update in ETS immediately (`100ms` memory path) and schedules
  a lazy database flush within `persist_within_ms` (default `1000ms`).
  """
  def stage_deferred(scope_kind, scope_id, kind, value, key \\ "") when is_map(value) do
    ensure_pending_ets!()
    Doc.put_ets_overlay(scope_kind, scope_id, kind, value, 0, key)
    :ets.insert(@pending_ets, {{scope_kind, scope_id, kind, key}, value})
    :ok
  end

  @doc """
  Flushes all pending deferred ETS updates to Ecto immediately (`REQ-DUR-05`).
  Safe to call inside or outside an existing Ecto transaction.
  """
  def flush_now! do
    ensure_pending_ets!()
    Storage.commit(fn _seq -> :ok end)
    :ok
  end

  def pending_count do
    ensure_pending_ets!()
    :ets.info(@pending_ets, :size)
  end

  def ensure_pending_ets! do
    case :ets.whereis(@pending_ets) do
      :undefined ->
        :ets.new(@pending_ets, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])

      _tid ->
        @pending_ets
    end
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    ensure_pending_ets!()
    Doc.ensure_ets!()
    interval = Keyword.get(opts, :flush_interval_ms, @default_flush_interval_ms)
    schedule_tick(interval)
    {:ok, %{interval: interval}}
  end

  @impl true
  def terminate(_reason, _state) do
    try do
      flush_now!()
    rescue
      _ -> :ok
    end

    :ok
  end

  @impl true
  def handle_info(:flush_tick, state) do
    try do
      flush_now!()
    rescue
      e ->
        require Logger
        Logger.error("Periodic flush failed: #{Exception.message(e)}")
    end

    schedule_tick(state.interval)
    {:noreply, state}
  end

  defp schedule_tick(interval) do
    Process.send_after(self(), :flush_tick, interval)
  end
end
