defmodule SuperPi.UI.Broker do
  @moduledoc """
  Carries a question from a running turn to a client that can answer it, and the answer back.

  A tool (`ask_question`) calls `ask/3`. The broker publishes a `ui_request` event on the
  conversation topic and blocks the caller until a client calls `respond/2`, the conversation
  is cancelled (`cancel_pending/1`), or the timeout passes.

  Only a client that has registered with `register_responder/1` can answer. The CLI chat and
  an RPC client that watches a conversation register. The HTTP gateway cannot prompt a user, so
  with no responder `ask/3` returns `{:error, :no_interactive_client}` at once instead of waiting.

  Pending questions live in memory. If the node stops mid-question the turn is restarted by the
  task engine and the model asks again. Nothing is answered by default.
  """

  @pending :super_pi_ui_pending
  @responders :super_pi_ui_responders

  @doc false
  def create_tables do
    for {table, type} <- [{@pending, :set}, {@responders, :bag}], :ets.whereis(table) == :undefined do
      try do
        :ets.new(table, [:named_table, :public, type])
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end

  @doc "Registers the calling process as able to answer questions for `conversation_id`."
  def register_responder(conversation_id) do
    create_tables()
    :ets.insert(@responders, {conversation_id, self()})
    :ok
  end

  @doc "True when at least one live process can answer for the conversation."
  def responder?(conversation_id) do
    create_tables()

    @responders
    |> :ets.lookup(conversation_id)
    |> Enum.any?(fn {_id, pid} -> Process.alive?(pid) end)
  end

  @doc """
  Asks `request` (a map such as `%{"kind" => "questionnaire", "questions" => [...]}`) and waits.

  Returns `{:ok, value}`, `{:error, :no_interactive_client}`, `{:error, :cancelled}` or
  `{:error, :timeout}`.
  """
  def ask(conversation_id, request, timeout) when is_map(request) do
    create_tables()

    if responder?(conversation_id) do
      request_id = "ui-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
      :ets.insert(@pending, {request_id, conversation_id, self()})

      event =
        request
        |> Map.merge(%{"type" => "ui_request", "request_id" => request_id, "conversation_id" => conversation_id})
        |> Map.put_new("timestamp_ms", System.system_time(:millisecond))

      Phoenix.PubSub.broadcast(SuperPi.PubSub, "conversation:#{conversation_id}", {:conversation_event, conversation_id, event})

      receive do
        {:ui_response, ^request_id, {:ok, value}} -> {:ok, value}
        {:ui_response, ^request_id, {:error, reason}} -> {:error, reason}
      after
        timeout -> {:error, :timeout}
      end
      |> tap(fn _ -> :ets.delete(@pending, request_id) end)
    else
      {:error, :no_interactive_client}
    end
  end

  @doc "Delivers an answer. `{:error, :unknown_request}` when no question is waiting under that id."
  def respond(request_id, value) do
    deliver(request_id, {:ok, value})
  end

  @doc "The conversation a waiting question belongs to, or `nil`."
  def conversation_of(request_id) do
    create_tables()

    case :ets.lookup(@pending, request_id) do
      [{^request_id, conversation_id, _pid}] -> conversation_id
      [] -> nil
    end
  end

  @doc "Ends every question that waits on the conversation with `{:error, :cancelled}`."
  def cancel_pending(conversation_id) do
    create_tables()

    for {request_id, ^conversation_id, _pid} <- :ets.tab2list(@pending) do
      deliver(request_id, {:error, :cancelled})
    end

    :ok
  end

  defp deliver(request_id, outcome) do
    create_tables()

    case :ets.lookup(@pending, request_id) do
      [{^request_id, _conversation_id, pid}] ->
        :ets.delete(@pending, request_id)
        send(pid, {:ui_response, request_id, outcome})
        :ok

      [] ->
        {:error, :unknown_request}
    end
  end
end
