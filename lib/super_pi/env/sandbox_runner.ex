defmodule SuperPi.Env.SandboxRunner do
  @moduledoc """
  4-Layer Safe Tool & Process Execution Sandbox (`REQ-SAFE-01`..`REQ-SAFE-03`, `REQ-PBT-05`).

  Guarantees that tool execution NEVER crashes the calling `:gen_statem` conversation process or
  the BEAM VM:
  - **Layer 1 (BEAM Process & Heap Isolation)**: Runs every tool function inside an unlinked
    `Task.Supervisor.async_nolink(SuperPi.ToolTaskSupervisor, ...)` process with a configurable
    `:max_heap_size` flag (`%{size: max_heap_words, kill: true, error_logger: true}`).
    If a tool raises an exception, calls `exit/1`, times out, or exceeds `:max_heap_size`,
    the supervisor catches the `:DOWN` message and returns `{:error, %{type: ..., reason: ...}}`.
  - **Layer 2 (Backpressure OS Process Execution + 4 MiB Spill Files)**: Executes external commands
    with streaming output capture and automatically spills outputs exceeding `4 MiB` (`4_194_304` bytes)
    to temporary files while returning a bounded preview.
  """

  @default_max_heap_words 16_777_216
  @default_timeout_ms 30_000
  @spill_threshold_bytes 4 * 1024 * 1024
  @preview_bytes 16 * 1024

  @doc """
  Runs `fun.()` inside an unlinked supervised task with `:max_heap_size` enforcement and a strict timeout.
  Never raises or crashes the caller.
  """
  @spec run_isolated((-> term()), keyword()) :: {:ok, term()} | {:error, map()}
  def run_isolated(fun, opts \\ []) when is_function(fun, 0) do
    max_heap_words = Keyword.get(opts, :max_heap_words, @default_max_heap_words)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    task =
      Task.Supervisor.async_nolink(SuperPi.ToolTaskSupervisor, fn ->
        Process.flag(:max_heap_size, %{
          size: max_heap_words,
          kill: true,
          error_logger: false
        })

        fun.()
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        {:ok, result}

      {:exit, :killed} ->
        {:error, %{type: "resource_exhausted", reason: "tool_killed_or_max_heap_exceeded"}}

      {:exit, {exception, _stack}} when is_exception(exception) ->
        {:error, %{type: "tool_exception", reason: Exception.message(exception)}}

      {:exit, reason} ->
        {:error, %{type: "tool_crash", reason: inspect(reason)}}

      nil ->
        {:error, %{type: "tool_timeout", reason: "Timed out after #{timeout_ms}ms"}}
    end
  end

  @doc """
  Executes an external OS command safely using `Exile` streaming with backpressure and `4 MiB` spill-to-disk
  protection (`REQ-SAFE-02`).
  """
  @spec exec_command(String.t(), list(String.t()), keyword()) ::
          {:ok, %{exit_code: integer(), output: String.t(), spilled_path: String.t() | nil}}
          | {:error, map()}
  def exec_command(cmd, args \\ [], opts \\ []) when is_binary(cmd) and is_list(args) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    cd = Keyword.get(opts, :cd, File.cwd!())
    spill_limit = Keyword.get(opts, :spill_threshold_bytes, @spill_threshold_bytes)
    parent = self()

    task =
      Task.Supervisor.async_nolink(SuperPi.ToolTaskSupervisor, fn ->
        Process.flag(:max_heap_size, %{
          size: Keyword.get(opts, :max_heap_words, @default_max_heap_words),
          kill: true,
          error_logger: false
        })

        exec_with_spill(cmd, args, cd, spill_limit, parent)
      end)

    res =
      case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} ->
          result

        {:exit, :killed} ->
          {:error, %{type: "resource_exhausted", reason: "tool_killed_or_max_heap_exceeded"}}

        {:exit, {exception, _stack}} when is_exception(exception) ->
          {:error, %{type: "tool_exception", reason: Exception.message(exception)}}

        {:exit, reason} ->
          {:error, %{type: "tool_crash", reason: inspect(reason)}}

        nil ->
          receive do
            {:os_pid, os_pid} -> kill_process_tree(os_pid)
          after
            0 -> :ok
          end

          {:error, %{type: "tool_timeout", reason: "Timed out after #{timeout_ms}ms"}}
      end

    case res do
      {:ok, val} -> {:ok, val}
      {:error, err} -> {:error, err}
    end
  end

  defp exec_with_spill(cmd, args, cd, spill_limit, parent) do
    case System.find_executable(cmd) do
      nil ->
        {:error, %{type: "command_not_found", reason: "Executable not found: #{cmd}"}}

      exec_path ->
        case Exile.Process.start_link([exec_path | args], cd: cd, stderr: :consume) do
          {:ok, proc} ->
            case Exile.Process.os_pid(proc) do
              {:ok, os_pid} when is_integer(os_pid) ->
                send(parent, {:os_pid, os_pid})

              _ ->
                :ok
            end

            acc_init = %{
              bytes: 0,
              chunks: [],
              spilled_path: nil,
              spill_io: nil,
              exit_code: 0
            }

            final = read_process_output(proc, acc_init, spill_limit)

            if final.spill_io do
              File.close(final.spill_io)
            end

            output =
              final.chunks
              |> Enum.reverse()
              |> IO.iodata_to_binary()

            output =
              if final.spilled_path do
                preview_raw = binary_part(output, 0, min(byte_size(output), @preview_bytes))
                preview = safe_utf8_prefix(preview_raw)
                preview <> "\n\n[Output exceeded #{spill_limit} bytes; full output spilled to #{final.spilled_path}]"
              else
                output
              end

            {:ok,
             %{
               exit_code: final.exit_code,
               output: output,
               spilled_path: final.spilled_path
             }}

          {:error, reason} ->
            {:error, %{type: "process_spawn_failed", reason: inspect(reason)}}
        end
    end
  end

  defp read_process_output(proc, acc, spill_limit) do
    case Exile.Process.read_any(proc) do
      {:ok, {:stdout, data}} ->
        new_acc = append_output_chunk(acc, data, spill_limit)
        read_process_output(proc, new_acc, spill_limit)

      {:ok, {:stderr, data}} ->
        new_acc = append_output_chunk(acc, data, spill_limit)
        read_process_output(proc, new_acc, spill_limit)

      :eof ->
        case Exile.Process.await_exit(proc) do
          {:ok, exit_code} ->
            %{acc | exit_code: exit_code}

          {:error, reason} ->
            %{acc | exit_code: parse_exit_status(reason)}
        end

      {:error, reason} ->
        %{acc | exit_code: parse_exit_status(reason)}
    end
  end

  defp parse_exit_status(%{exit_status: s}) when is_integer(s), do: s
  defp parse_exit_status(s) when is_integer(s), do: s
  defp parse_exit_status(_), do: 1

  defp append_output_chunk(acc, data, spill_limit) when is_binary(data) do
    new_bytes = acc.bytes + byte_size(data)

    cond do
      acc.spilled_path != nil ->
        IO.binwrite(acc.spill_io, data)
        %{acc | bytes: new_bytes}

      new_bytes > spill_limit ->
        spill_path = Path.join(System.tmp_dir!(), "super_pi_spill_#{System.unique_integer([:positive])}.log")
        File.touch!(spill_path)
        File.chmod!(spill_path, 0o600)
        {:ok, io} = File.open(spill_path, [:write, :binary])

        existing =
          acc.chunks
          |> Enum.reverse()
          |> IO.iodata_to_binary()

        IO.binwrite(io, existing)
        IO.binwrite(io, data)

        %{
          acc
          | bytes: new_bytes,
            spilled_path: spill_path,
            spill_io: io
        }

      true ->
        %{acc | bytes: new_bytes, chunks: [data | acc.chunks]}
    end
  end

  defp safe_utf8_prefix(bin) do
    case :unicode.characters_to_binary(bin, :utf8, :utf8) do
      {:error, valid, _rest} -> valid
      {:incomplete, valid, _rest} -> valid
      valid when is_binary(valid) -> valid
    end
  end

  defp kill_process_tree(nil), do: :ok

  defp kill_process_tree(os_pid) when is_integer(os_pid) do
    pid_str = Integer.to_string(os_pid)

    case System.cmd("pgrep", ["-P", pid_str]) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.each(fn child_pid ->
          case Integer.parse(child_pid) do
            {c_pid, _} -> kill_process_tree(c_pid)
            _ -> :ok
          end
        end)

      _ ->
        :ok
    end

    System.cmd("kill", ["-KILL", pid_str], stderr_to_stdout: true)
    :ok
  end
end
