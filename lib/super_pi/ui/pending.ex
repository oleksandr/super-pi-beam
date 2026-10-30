defmodule SuperPi.UI.Pending do
  @moduledoc """
  Hands a decision from `before_tool` to `wrap_tool` for the same tool call.

  `before_tool` runs in the conversation machine, `wrap_tool` in the tool task, and the machine
  must not block on a human (it would stop answering `cancel`, `steer`, `get_state` and `compact`).
  So a plugin that wants an answer from a human lets the call through in `before_tool`, leaves a note
  here and asks in `wrap_tool`, which runs in the task. The note is keyed by conversation and tool
  call id. `take/2` removes it. A note that nobody takes (a later plugin blocked the call) expires
  after ten minutes and is dropped on the next `put/3`.
  """

  use GenServer

  @table :super_pi_ui_pending
  @ttl_ms 600_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_), do: {:ok, :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])}

  @doc "Leaves a note for the tool call."
  @spec put(integer(), term(), term()) :: :ok
  def put(conversation_id, tool_call_id, note) do
    sweep()

    :ets.insert(
      @table,
      {{conversation_id, tool_call_id}, note, System.monotonic_time(:millisecond)}
    )

    :ok
  end

  @doc "Removes and returns the note of the tool call, or `nil`."
  @spec take(integer(), term()) :: term() | nil
  def take(conversation_id, tool_call_id) do
    case :ets.take(@table, {conversation_id, tool_call_id}) do
      [{_, note, _}] -> note
      [] -> nil
    end
  end

  defp sweep do
    cutoff = System.monotonic_time(:millisecond) - @ttl_ms
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
    :ok
  end
end
