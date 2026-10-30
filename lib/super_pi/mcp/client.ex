defmodule SuperPi.MCP.Client do
  @moduledoc """
  Client for one Model Context Protocol server over stdio.

  The client starts the server as an OS process, runs the `initialize` handshake, lists
  the server's tools (following `nextCursor`), and then forwards `tools/call` requests.
  Messages are one JSON-RPC 2.0 object per line.

  Use `SuperPi.MCP.Manager` to start every configured server and expose its tools to the
  agent. This module only speaks the protocol. The HTTP transports are not implemented.

  A server writes logs to stderr. The port does not capture stderr, so those logs go to
  the stderr of the Super-Pi process, never into the JSON stream.
  """

  use GenServer
  require Logger

  @protocol_version "2024-11-05"
  @max_line 4 * 1024 * 1024

  defstruct [
    :name,
    :port,
    :server_info,
    status: :starting,
    buf: "",
    next_id: 1,
    pending: %{},
    tools: [],
    waiters: []
  ]

  # --- Public API ---

  @doc """
  Starts a client. Options: `:name` (server name), `:command`, `:args`, `:env` (map), `:cwd`.
  Returns `{:error, {:command_not_found, command}}` when the executable does not exist.
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
    command = Keyword.fetch!(opts, :command)

    case System.find_executable(command) do
      nil ->
        {:stop, {:command_not_found, command}}

      path ->
        port_opts =
          [
            :binary,
            :exit_status,
            :hide,
            {:line, @max_line},
            {:args, Enum.map(Keyword.get(opts, :args, []), &to_string/1)},
            {:env, env_list(Keyword.get(opts, :env, %{}))}
          ] ++ if(cwd = Keyword.get(opts, :cwd), do: [{:cd, cwd}], else: [])

        port = Port.open({:spawn_executable, path}, port_opts)
        state = %__MODULE__{name: Keyword.get(opts, :name, command), port: port}
        {:ok, send_request(state, "initialize", initialize_params(), :initialize)}
    end
  end

  @impl true
  def handle_call(:await_ready, _from, %{status: :ready} = state), do: {:reply, :ok, state}
  def handle_call(:await_ready, _from, %{status: {:failed, reason}} = state), do: {:reply, {:error, reason}, state}
  def handle_call(:await_ready, from, state), do: {:noreply, %{state | waiters: [from | state.waiters]}}

  def handle_call(:tools, _from, state), do: {:reply, state.tools, state}

  def handle_call({:call_tool, _tool, _args, _timeout}, _from, %{status: status} = state) when status != :ready do
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
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    handle_line(state.buf <> line, %{state | buf: ""})
  end

  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state) do
    {:noreply, %{state | buf: state.buf <> chunk}}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    Logger.warning("[MCP] server #{state.name} exited with status #{code}")
    state = fail_all(state, {:server_exited, code})
    {:stop, :normal, state}
  end

  def handle_info({:call_timeout, id}, state) do
    case Map.pop(state.pending, id) do
      {{:call, from}, pending} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | pending: pending}}

      {_other, _pending} ->
        {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port}) when is_port(port) do
    # Closing the port closes the server's stdin, which ends a well-behaved stdio server.
    if Port.info(port), do: Port.close(port)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # --- Protocol ---

  defp initialize_params do
    %{
      "protocolVersion" => @protocol_version,
      "capabilities" => %{},
      "clientInfo" => %{"name" => "super-pi-beam", "version" => "0.1.0"}
    }
  end

  defp handle_line(line, state) do
    case Jason.decode(line) do
      {:ok, %{"id" => id, "method" => method}} when is_binary(method) ->
        {:noreply, reply_to_server_request(state, id, method)}

      {:ok, %{"id" => id} = message} ->
        {:noreply, handle_response(state, id, message)}

      {:ok, _notification} ->
        {:noreply, state}

      {:error, _} ->
        # Not JSON: a server that prints a banner to stdout. Ignore it.
        {:noreply, state}
    end
  end

  # The server may send its own requests. `ping` gets an empty result, anything else is refused.
  defp reply_to_server_request(state, id, "ping"), do: send_message(state, %{"jsonrpc" => "2.0", "id" => id, "result" => %{}})

  defp reply_to_server_request(state, id, method) do
    send_message(state, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => -32601, "message" => "Method not supported by this client: #{method}"}
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

  defp dispatch_response(kind, %{"error" => error}, state) when kind in [:initialize, :list_tools] do
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
    Port.command(state.port, Jason.encode!(message) <> "\n")
    state
  end

  defp env_list(env) when is_map(env) do
    Enum.map(env, fn {k, v} -> {String.to_charlist(to_string(k)), String.to_charlist(to_string(v))} end)
  end

  defp env_list(_), do: []
end
