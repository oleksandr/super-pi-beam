defmodule SuperPi.MCP.Client do
  @moduledoc """
  Client for one Model Context Protocol server, over stdio or Streamable HTTP.

  The client runs the `initialize` handshake, lists the server's tools (following
  `nextCursor`), and then forwards `tools/call` requests. It owns the protocol: request ids,
  timeouts and the handshake. A `SuperPi.MCP.Transport` moves the messages:

    * `command` starts the server as an OS process (`SuperPi.MCP.Transport.Stdio`).
    * `url` talks to a hosted server (`SuperPi.MCP.Transport.StreamableHTTP`).

  Use `SuperPi.MCP.Manager` to start every configured server and expose its tools to the
  agent. This module only speaks the protocol. It declares no client capabilities, so a server
  cannot ask for sampling, roots or elicitation; it may still send `ping`.
  """

  use GenServer
  require Logger

  alias SuperPi.MCP.Transport.{Stdio, StreamableHTTP}

  defstruct [
    :name,
    :transport,
    :tstate,
    :server_info,
    status: :starting,
    next_id: 1,
    pending: %{},
    tools: [],
    waiters: []
  ]

  # --- Public API ---

  @doc """
  Starts a client. Options: `:name` (server name) and either `:command`, `:args`, `:env` (map), `:cwd`
  (stdio) or `:url`, `:headers` (map, `${ENV_VAR}` is expanded) for Streamable HTTP. `:transport`
  names a `SuperPi.MCP.Transport` module explicitly.

  Returns `{:error, {:command_not_found, command}}` when the executable does not exist, and
  `{:error, {:invalid_url, url}}` or `{:error, {:missing_env, names}}` for a bad `url` entry.
  """
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Waits until the handshake and the tool listing finish. Returns `:ok` or `{:error, reason}`."
  def await_ready(pid, timeout \\ 10_000) do
    GenServer.call(pid, :await_ready, timeout)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, reason -> {:error, {:exit, reason}}
  end

  @doc "Tool definitions as the server returned them (`name`, `description`, `inputSchema`)."
  def tools(pid), do: GenServer.call(pid, :tools)

  @doc """
  Calls a tool. Returns `{:ok, result}` with the server's `tools/call` result map,
  or `{:error, reason}` for a protocol error, a timeout, or a server that exited.
  """
  def call_tool(pid, tool, args, timeout \\ 60_000) when is_binary(tool) and is_map(args) do
    GenServer.call(pid, {:call_tool, tool, args, timeout}, timeout + 5_000)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, reason -> {:error, {:exit, reason}}
  end

  # --- GenServer ---

  @impl true
  def init(opts) do
    # So `terminate/2` runs on a supervisor shutdown and closes the transport.
    Process.flag(:trap_exit, true)
    transport = Keyword.get_lazy(opts, :transport, fn -> transport_for(opts) end)

    case transport.start(opts) do
      {:ok, tstate} ->
        name = Keyword.get(opts, :name) || Keyword.get(opts, :command) || Keyword.get(opts, :url)
        state = %__MODULE__{name: name, transport: transport, tstate: tstate}
        {:ok, send_request(state, "initialize", initialize_params(transport), :initialize)}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  defp transport_for(opts) do
    if Keyword.get(opts, :url) && !Keyword.get(opts, :command), do: StreamableHTTP, else: Stdio
  end

  @impl true
  def handle_call(:await_ready, _from, %{status: :ready} = state), do: {:reply, :ok, state}

  def handle_call(:await_ready, _from, %{status: {:failed, reason}} = state),
    do: {:reply, {:error, reason}, state}

  def handle_call(:await_ready, from, state),
    do: {:noreply, %{state | waiters: [from | state.waiters]}}

  def handle_call(:tools, _from, state), do: {:reply, state.tools, state}

  def handle_call({:call_tool, _tool, _args, _timeout}, _from, %{status: status} = state)
      when status != :ready do
    {:reply, {:error, {:not_ready, status}}, state}
  end

  def handle_call({:call_tool, tool, args, timeout}, from, state) do
    params = %{"name" => tool, "arguments" => args}
    state = send_request(state, "tools/call", params, {:call, from})
    id = state.next_id - 1
    Process.send_after(self(), {:call_timeout, id}, timeout)
    {:noreply, state}
  end

  @impl true
  def handle_info({:call_timeout, id}, state) do
    case Map.pop(state.pending, id) do
      {{:call, from}, pending} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | pending: pending}}

      {_other, _pending} ->
        {:noreply, state}
    end
  end

  def handle_info(message, %{transport: transport, tstate: tstate} = state) do
    case transport.handle_info(tstate, message) do
      {:messages, messages, tstate} ->
        {:noreply, Enum.reduce(messages, %{state | tstate: tstate}, &handle_message/2)}

      {:ignore, tstate} ->
        {:noreply, %{state | tstate: tstate}}

      {:closed, reason, tstate} ->
        Logger.warning("[MCP] server #{state.name} closed: #{inspect(reason)}")
        state = fail_all(%{state | tstate: tstate}, reason)
        {:stop, :normal, state}
    end
  end

  @impl true
  def terminate(_reason, %{transport: transport, tstate: tstate}) when not is_nil(transport) do
    transport.close(tstate)
  end

  def terminate(_reason, _state), do: :ok

  # --- Protocol ---

  defp initialize_params(transport) do
    %{
      "protocolVersion" => transport.protocol_version(),
      "capabilities" => %{},
      "clientInfo" => %{"name" => "super-pi-beam", "version" => "0.1.0"}
    }
  end

  defp handle_message(%{"id" => id, "method" => method}, state) when is_binary(method) do
    reply_to_server_request(state, id, method)
  end

  defp handle_message(%{"id" => id} = message, state), do: handle_response(state, id, message)
  defp handle_message(_notification, state), do: state

  # The server may send its own requests. `ping` gets an empty result, anything else is refused.
  defp reply_to_server_request(state, id, "ping"),
    do: send_message(state, %{"jsonrpc" => "2.0", "id" => id, "result" => %{}})

  defp reply_to_server_request(state, id, method) do
    send_message(state, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{
        "code" => -32601,
        "message" => "Method not supported by this client: #{method}"
      }
    })
  end

  defp handle_response(state, id, message) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        state

      {kind, pending} ->
        dispatch_response(kind, message, %{state | pending: pending})
    end
  end

  defp dispatch_response(:initialize, %{"result" => result}, state) do
    state = %{state | server_info: Map.get(result, "serverInfo")}
    state = send_message(state, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
    send_request(state, "tools/list", %{}, :list_tools)
  end

  defp dispatch_response(:list_tools, %{"result" => result}, state) do
    tools = state.tools ++ List.wrap(Map.get(result, "tools"))

    case Map.get(result, "nextCursor") do
      cursor when is_binary(cursor) and cursor != "" ->
        send_request(%{state | tools: tools}, "tools/list", %{"cursor" => cursor}, :list_tools)

      _ ->
        ready(%{state | tools: tools})
    end
  end

  defp dispatch_response(kind, %{"error" => error}, state)
       when kind in [:initialize, :list_tools] do
    fail_all(state, {:handshake_failed, error})
  end

  defp dispatch_response({:call, from}, %{"result" => result}, state) do
    GenServer.reply(from, {:ok, result})
    state
  end

  defp dispatch_response({:call, from}, %{"error" => error}, state) do
    GenServer.reply(from, {:error, {:protocol_error, error}})
    state
  end

  defp dispatch_response(_kind, _message, state), do: state

  defp ready(state) do
    Enum.each(state.waiters, &GenServer.reply(&1, :ok))
    %{state | status: :ready, waiters: []}
  end

  defp fail_all(state, reason) do
    Enum.each(state.waiters, &GenServer.reply(&1, {:error, reason}))

    Enum.each(state.pending, fn
      {_id, {:call, from}} -> GenServer.reply(from, {:error, reason})
      _ -> :ok
    end)

    %{state | status: {:failed, reason}, waiters: [], pending: %{}}
  end

  defp send_request(state, method, params, kind) do
    id = state.next_id
    message = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
    state = send_message(state, message)
    %{state | next_id: id + 1, pending: Map.put(state.pending, id, kind)}
  end

  defp send_message(state, message) do
    %{state | tstate: state.transport.send_message(state.tstate, message)}
  end
end
