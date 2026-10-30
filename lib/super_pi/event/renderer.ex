defmodule SuperPi.Event.Renderer do
  @moduledoc """
  Turns `SuperPi.Event`s into the output of one protocol.

  A renderer is a pure state machine, not a process. The transport process owns the socket and the
  renderer owns only its projection state, so a renderer needs no socket to be tested. This is the
  shape of `SuperPi.RPC.Server.handle_rpc_payload/2`, which is pure for the same reason.

  Cross-event state is why `init/1` exists. AG-UI must open and close a text message around a run of
  bare deltas, and ACP tracks a tool call from `pending` to `completed`.

      state = Renderer.OpenAI.init(id: "chatcmpl-1", model: "super-pi-code")
      {chunks, state} = Renderer.OpenAI.render(event, state)
      {tail, _state} = Renderer.OpenAI.flush(state)

  | Renderer | Output per call |
  |---|---|
  | `SuperPi.Event.Renderer.OpenAI` | chat completion chunk maps |
  | `SuperPi.Event.Renderer.RPC` | the wire map (identity) |
  | `SuperPi.Event.Renderer.TUI` | terminal lines |
  | `SuperPi.Event.Renderer.ACP` | `session/update` notification params |
  | `SuperPi.Event.Renderer.AGUI` | AG-UI event maps |
  """

  alias SuperPi.Event

  @doc "Builds the initial state from options."
  @callback init(opts :: keyword()) :: term()

  @doc "Renders one event. Returns the output items, possibly none, and the next state."
  @callback render(Event.t(), state :: term()) :: {[term()], term()}

  @doc "Ends the stream: output that closes what is open. Returns the final output and state."
  @callback flush(state :: term()) :: {[term()], term()}

  @doc "Renders a list of events and flushes, for tests and for replay of a stored history."
  @spec render_all(module(), [Event.t()], keyword()) :: [term()]
  def render_all(renderer, events, opts \\ []) do
    {out, state} =
      Enum.reduce(events, {[], renderer.init(opts)}, fn ev, {acc, st} ->
        {items, st} = renderer.render(ev, st)
        {acc ++ items, st}
      end)

    {tail, _} = renderer.flush(state)
    out ++ tail
  end
end
