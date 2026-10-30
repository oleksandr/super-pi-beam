defmodule SuperPi.MCP.Transport do
  @moduledoc """
  How `SuperPi.MCP.Client` talks to one MCP server. The client owns the protocol (handshake,
  request ids, timeouts); a transport only moves JSON-RPC messages.

  A transport runs inside the client process and keeps its state in a term the client holds.
  Whatever the transport spawns (a port, an HTTP request task) sends its results to the client
  process as ordinary messages. The client hands every message it does not know to
  `c:handle_info/2`, which turns it into JSON-RPC messages or reports that the server is gone.

  Built in: `SuperPi.MCP.Transport.Stdio` (a child process) and
  `SuperPi.MCP.Transport.StreamableHTTP` (a URL).
  """

  @type state :: term()
  @type message :: map()

  @doc "The `protocolVersion` the client offers in `initialize` over this transport."
  @callback protocol_version() :: String.t()

  @doc "Opens the transport. The calling process is the owner and receives its messages."
  @callback start(opts :: keyword()) :: {:ok, state()} | {:error, term()}

  @doc "Sends one JSON-RPC message. Never waits for the answer: it arrives through `c:handle_info/2`."
  @callback send_message(state(), message()) :: state()

  @doc """
  Handles a message sent to the owner. Returns the JSON-RPC messages it carried, `:ignore`
  for a message that carries none, or `:closed` when the server is gone.
  """
  @callback handle_info(state(), term()) ::
              {:messages, [message()], state()} | {:ignore, state()} | {:closed, term(), state()}

  @doc "Releases the transport's resources."
  @callback close(state()) :: :ok
end
