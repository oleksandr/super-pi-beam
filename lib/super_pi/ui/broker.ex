defmodule SuperPi.UI.Broker do
  @moduledoc """
  Carries a question from a running turn to a client that can answer it, and the answer back.
  Works across nodes: the machine that asks and the client that answers can be on different nodes.

  A tool (`ask_question`) calls `ask/3`. The broker publishes a `ui_request` event on the
  conversation topic and blocks the caller until a client calls `respond/2`, the conversation is
  cancelled (`cancel_pending/1`), every responder has left, or the timeout passes.

  Only a client that has registered with `register_responder/1` can answer. The CLI chat and an RPC
  client that watches a conversation register. The HTTP gateway cannot prompt a user, so with no
  responder `ask/3` returns `{:error, :no_interactive_client}` at once instead of waiting.

  Membership lives in `:pg` process groups (scope `:super_pi_pg`). `:pg` spans the connected nodes
  and drops a process that exits, so no table needs cleaning.

  Pending questions are in memory. If the node that asks stops mid-question, the task engine
  restarts the turn elsewhere and the model asks again. Nothing is answered by default.
  """

  @scope :super_pi_pg

  @doc false
  def scope, do: @scope

  @doc false
  def child_spec(_opts), do: %{id: __MODULE__, start: {:pg, :start_link, [@scope]}, type: :worker}

  @doc "Registers the calling process as able to answer questions for `conversation_id`."
  def register_responder(conversation_id) do
    group = {:ui_responder, conversation_id}
    if self() not in :pg.get_local_members(@scope, group), do: :pg.join(@scope, group, self())
    :ok
  end

  @doc "True when at least one live process, on any node, can answer for the conversation."
  def responder?(conversation_id) do
    # `:pg` drops a process that exited a moment after it ends, so skip dead local ones.
    @scope
    |> :pg.get_members({:ui_responder, conversation_id})
    |> Enum.any?(fn pid -> node(pid) != node() or Process.alive?(pid) end)
  end

  @doc """
  Asks `request` (a map such as `%{"kind" => "questionnaire", "questions" => [...]}`) and waits.

  Returns `{:ok, value}`, `{:error, :no_interactive_client}`, `{:error, :cancelled}` or
  `{:error, :timeout}`.
  """
  def ask(conversation_id, request, timeout) when is_map(request) do
    if responder?(conversation_id) do
      request_id = "ui-#{conversation_id}-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
      pending = {:ui_pending, request_id}
      asking = {:ui_asking, conversation_id}
      :pg.join(@scope, pending, self())
      :pg.join(@scope, asking, self())
      {monitor, _members} = :pg.monitor(@scope, {:ui_responder, conversation_id})

      event =
        request
        |> Map.merge(%{"type" => "ui_request", "request_id" => request_id, "conversation_id" => conversation_id})
        |> Map.put_new("timestamp_ms", System.system_time(:millisecond))

      Phoenix.PubSub.broadcast(SuperPi.PubSub, "conversation:#{conversation_id}", {:conversation_event, conversation_id, event})

      try do
        await(request_id, conversation_id, monitor, deadline(timeout))
      after
        :pg.leave(@scope, pending, self())
        :pg.leave(@scope, asking, self())
        :pg.demonitor(@scope, monitor)
        flush(monitor)
      end
    else
      {:error, :no_interactive_client}
    end
  end

  defp deadline(:infinity), do: :infinity
  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp await(request_id, conversation_id, monitor, deadline) do
    wait =
      case deadline do
        :infinity -> :infinity
        at -> max(at - System.monotonic_time(:millisecond), 0)
      end

    receive do
      {:ui_response, ^request_id, {:ok, value}} ->
        {:ok, value}

      {:ui_cancel, ^conversation_id} ->
        {:error, :cancelled}

      # A responder left. If it was the last one, nobody can answer any more.
      {^monitor, :leave, _group, _pids} ->
        if responder?(conversation_id),
          do: await(request_id, conversation_id, monitor, deadline),
          else: {:error, :cancelled}

      {^monitor, :join, _group, _pids} ->
        await(request_id, conversation_id, monitor, deadline)
    after
      wait -> {:error, :timeout}
    end
  end

  defp flush(monitor) do
    receive do
      {^monitor, _, _, _} -> flush(monitor)
    after
      0 -> :ok
    end
  end

  @doc "Delivers an answer. `{:error, :unknown_request}` when no question is waiting under that id."
  def respond(request_id, value) do
    case :pg.get_members(@scope, {:ui_pending, request_id}) do
      [pid | _] ->
        send(pid, {:ui_response, request_id, {:ok, value}})
        :ok

      [] ->
        {:error, :unknown_request}
    end
  end

  @doc "The conversation a waiting question belongs to, or `nil`."
  def conversation_of(request_id) when is_binary(request_id) do
    with ["ui", conv, _rest] <- String.split(request_id, "-", parts: 3),
         {id, ""} <- Integer.parse(conv),
         [_ | _] <- :pg.get_members(@scope, {:ui_pending, request_id}) do
      id
    else
      _ -> nil
    end
  end

  def conversation_of(_), do: nil

  @doc "Ends every question that waits on the conversation with `{:error, :cancelled}`."
  def cancel_pending(conversation_id) do
    for pid <- :pg.get_members(@scope, {:ui_asking, conversation_id}) do
      send(pid, {:ui_cancel, conversation_id})
    end

    :ok
  end

  @doc false
  def create_tables, do: :ok
end
