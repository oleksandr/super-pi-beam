defmodule SuperPi.Durable.DocCache do
  @moduledoc """
  Keeps the document cache (`SuperPi.Durable.Doc`) coherent across nodes.

  After a commit, the writer broadcasts the keys it wrote (`broadcast/1`). Every other node drops
  those entries and reads the new value from the database on its next read. On a single node
  nothing is sent.

  This is best effort and is backed by the cache TTL: a node can still read an old value for a
  moment after another node commits.
  """

  use GenServer

  @topic "super_pi:doc_cache"

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Tells the other nodes that these cache keys changed. Does nothing without other nodes."
  def broadcast([]), do: :ok

  def broadcast(keys) when is_list(keys) do
    if Node.list() != [] do
      Phoenix.PubSub.broadcast_from(SuperPi.PubSub, self(), @topic, {:doc_invalidate, node(), Enum.uniq(keys)})
    end

    :ok
  end

  @impl true
  def init(nil) do
    Phoenix.PubSub.subscribe(SuperPi.PubSub, @topic)
    {:ok, nil}
  end

  @impl true
  def handle_info({:doc_invalidate, origin, keys}, state) when origin != node() do
    SuperPi.Durable.Doc.cache_invalidate(keys)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}
end
