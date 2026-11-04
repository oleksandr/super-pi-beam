defmodule SuperPi.AI.Providers.OpenAI.Auth do
  @moduledoc false

  use GenServer

  @default_timeout_ms 10_000
  @default_cache_ttl_ms 60_000
  @expiry_margin_ms 30_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def token(command) do
    # The command itself has a deadline. Concurrent callers queue behind a refresh and then
    # share its cached result, so their call must not time out while waiting for the server.
    GenServer.call(__MODULE__, {:token, command}, :infinity)
  end

  @impl true
  def init(cache), do: {:ok, cache}

  @impl true
  def handle_call({:token, command}, _from, cache) do
    now = System.monotonic_time(:millisecond)

    case Map.get(cache, command) do
      {token, expires_at} when now < expires_at ->
        {:reply, {:ok, token}, cache}

      _ ->
        case run_command(command) do
          {:ok, token} ->
            case token_ttl_ms(token) do
              ttl when is_integer(ttl) and ttl > 0 ->
                expires_at = System.monotonic_time(:millisecond) + ttl
                {:reply, {:ok, token}, Map.put(cache, command, {token, expires_at})}

              0 ->
                {:reply, {:ok, token}, Map.delete(cache, command)}

              _ ->
                {:reply, {:error, :openai_auth_expired}, Map.delete(cache, command)}
            end

          {:error, reason} ->
            {:reply, {:error, reason}, Map.delete(cache, command)}
        end
    end
  end

  defp run_command(command) do
    task =
      Task.Supervisor.async_nolink(SuperPi.ToolTaskSupervisor, fn ->
        try do
          case System.find_executable(command) do
            nil -> {:error, {:openai_auth_failed, :not_found, "Executable not found: #{command}"}}
            executable -> execute(executable)
          end
        rescue
          error -> {:error, {:openai_auth_failed, :exception, Exception.message(error)}}
        end
      end)

    case Task.yield(task, timeout_ms()) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        {:error, {:openai_auth_failed, :exit, inspect(reason)}}

      nil ->
        # Exile owns the subprocess and terminates it when its owner task exits.
        Task.shutdown(task, :brutal_kill)
        {:error, {:openai_auth_timeout, timeout_ms()}}
    end
  end

  defp execute(command) do
    # The stream API supports separate stderr consumption in both its contract and typespec.
    {stdout, stderr, status} =
      Exile.stream([command], input: [], stderr: :consume, exit_timeout: :infinity)
      |> Enum.reduce({"", "", nil}, fn
        {:stdout, data}, {stdout, stderr, status} ->
          output = stdout <> IO.iodata_to_binary(data)
          if byte_size(output) > 65_536, do: throw(:auth_output_limit)
          {output, stderr, status}

        {:stderr, data}, {stdout, stderr, status} ->
          {stdout, String.slice(stderr <> IO.iodata_to_binary(data), 0, 4_096), status}

        {:exit, {:status, status}}, {stdout, stderr, _} ->
          {stdout, stderr, status}

        {:exit, reason}, {stdout, stderr, _} ->
          {stdout, stderr, reason}
      end)

    token = String.trim(stdout)

    cond do
      status != 0 ->
        output = if String.trim(stderr) == "", do: stdout, else: stderr
        {:error, {:openai_auth_failed, status, String.slice(String.trim(output), 0, 500)}}

      token == "" ->
        {:error, {:openai_auth_failed, 0, "command returned an empty token"}}

      true ->
        {:ok, token}
    end
  catch
    :auth_output_limit -> {:error, {:openai_auth_failed, :output_limit, "token exceeds 64 KiB"}}
  end

  defp token_ttl_ms(token) do
    configured_ttl =
      Application.get_env(:super_pi, :openai_auth_cache_ttl_ms, @default_cache_ttl_ms)

    ttl = if is_integer(configured_ttl) and configured_ttl >= 0, do: configured_ttl, else: 0

    case String.split(token, ".") do
      [_header, payload, _signature] ->
        with {:ok, decoded} <- Base.url_decode64(payload, padding: false),
             {:ok, %{"exp" => exp}} when is_integer(exp) <- Jason.decode(decoded) do
          remaining = exp * 1_000 - System.system_time(:millisecond)

          if remaining <= 0,
            do: :expired,
            else: min(ttl, max(0, remaining - @expiry_margin_ms))
        else
          _ -> ttl
        end

      _ ->
        ttl
    end
  end

  defp timeout_ms do
    case Application.get_env(:super_pi, :openai_auth_timeout_ms, @default_timeout_ms) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_timeout_ms
    end
  end
end
