defmodule SuperPi.MCP.Transport.Stdio do
  @moduledoc """
  Stdio transport: the server runs as an OS process and speaks one JSON-RPC 2.0 object per line.

  A server writes logs to stderr. The port does not capture stderr, so those logs go to
  the stderr of the Super-Pi process, never into the JSON stream. A line that is not JSON
  (a banner on stdout) is ignored.
  """

  @behaviour SuperPi.MCP.Transport

  @protocol_version "2024-11-05"
  @max_line 4 * 1024 * 1024

  @impl true
  def protocol_version, do: @protocol_version

  @doc """
  Options: `:command`, `:args`, `:env` (map), `:cwd`.
  Returns `{:error, {:command_not_found, command}}` when the executable does not exist.
  """
  @impl true
  def start(opts) do
    command = Keyword.fetch!(opts, :command)

    case System.find_executable(command) do
      nil ->
        {:error, {:command_not_found, command}}

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

        {:ok, %{port: Port.open({:spawn_executable, path}, port_opts), buf: ""}}
    end
  end

  @impl true
  def send_message(%{port: port} = state, message) do
    Port.command(port, Jason.encode!(message) <> "\n")
    state
  end

  @impl true
  def handle_info(%{port: port, buf: buf} = state, {port, {:data, {:eol, line}}}) do
    {:messages, decode(buf <> line), %{state | buf: ""}}
  end

  def handle_info(%{port: port, buf: buf} = state, {port, {:data, {:noeol, chunk}}}) do
    {:ignore, %{state | buf: buf <> chunk}}
  end

  def handle_info(%{port: port} = state, {port, {:exit_status, code}}),
    do: {:closed, {:server_exited, code}, state}

  def handle_info(state, _other), do: {:ignore, state}

  @impl true
  def close(%{port: port}) when is_port(port) do
    # Closing the port closes the server's stdin, which ends a well-behaved stdio server.
    if Port.info(port), do: Port.close(port)
    :ok
  end

  def close(_state), do: :ok

  # Not JSON, or JSON that is not an object: a server that prints a banner to stdout. Ignore it.
  defp decode(line) do
    case Jason.decode(line) do
      {:ok, %{} = message} -> [message]
      _ -> []
    end
  end

  defp env_list(env) when is_map(env) do
    Enum.map(env, fn {k, v} ->
      {String.to_charlist(to_string(k)), String.to_charlist(to_string(v))}
    end)
  end

  defp env_list(_), do: []
end
