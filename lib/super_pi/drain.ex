defmodule SuperPi.Drain do
  @moduledoc """
  Graceful shutdown of a node (REQ-CLU-07).

  On SIGTERM the application calls `drain/1` before it stops. The node

  1. stops accepting new work: the gateway answers `503 shutting_down` (with `Retry-After`) and
     `GET /ready` returns 503, so a load balancer or Kubernetes sends traffic elsewhere; RPC
     refuses `session.open` and `session.submit`;
  2. waits for the conversation machines on this node to finish their running turns, up to
     `config :super_pi, drain_timeout_ms` (default 30 000);
  3. stops. Idle machines under `Horde.DynamicSupervisor` are restarted on the other nodes, and a
     turn that did not finish in time is resumed from the durable state by the machine that
     replaces it.
  """

  require Logger

  alias SuperPi.Conversation.Locator

  @key {__MODULE__, :accepting}

  @doc "True while the node accepts new work."
  def accepting?, do: :persistent_term.get(@key, true)

  @doc "Stops accepting new work."
  def stop_accepting, do: :persistent_term.put(@key, false)

  @doc "Accepts work again (used by tests, and after a cancelled shutdown)."
  def resume, do: :persistent_term.put(@key, true)

  @doc """
  Stops accepting work and waits until no local machine is busy. Returns `:drained` or
  `{:timeout, busy_conversation_ids}`.
  """
  def drain(timeout \\ nil) do
    timeout = timeout || Application.get_env(:super_pi, :drain_timeout_ms, 30_000)
    stop_accepting()
    Logger.info("[Drain] node #{node()} stopped accepting work; waiting for running turns (up to #{timeout} ms)")
    wait(System.monotonic_time(:millisecond) + timeout)
  end

  defp wait(deadline) do
    case busy_conversations() do
      [] ->
        Logger.info("[Drain] no running turns")
        :drained

      busy ->
        if System.monotonic_time(:millisecond) >= deadline do
          Logger.warning("[Drain] timeout with running turns on conversations #{inspect(busy)}; they resume elsewhere")
          {:timeout, busy}
        else
          Process.sleep(100)
          wait(deadline)
        end
    end
  end

  @doc "Ids of the conversations on this node whose machine is in the middle of a turn."
  def busy_conversations do
    for {id, pid} <- Locator.all(), node(pid) == node(), busy?(pid), do: id
  end

  defp busy?(pid) do
    case :gen_statem.call(pid, :get_state, 1_000) do
      {:idle, _data} -> false
      {_state, _data} -> true
    end
  catch
    :exit, _ -> false
  end
end
