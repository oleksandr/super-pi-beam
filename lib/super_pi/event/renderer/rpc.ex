defmodule SuperPi.Event.Renderer.RPC do
  @moduledoc """
  Identity renderer for the JSON-RPC server: the wire map of an event is what a watcher receives.
  The server adds batching and backpressure (`session.ack`) on top.
  """
  @behaviour SuperPi.Event.Renderer

  alias SuperPi.Event

  @impl true
  def init(_opts), do: nil

  @impl true
  def render(%Event{} = event, state), do: {[Event.to_wire(event)], state}

  @impl true
  def flush(state), do: {[], state}
end
