defmodule SuperPi.Plugins.InlineBash do
  @moduledoc """
  Inline Bash Plugin (migrated from Pi ecosystem `inline-bash.ts`).

  Expands `!{command}` expressions in user prompts directly on input before sending
  the message to the model. Eliminates a full LLM turn for simple state inspections
  (e.g. `!{git status --short}`, `!{mix test}`, `!{node --version}`).

  ### Configuration Options (`ctx[:config]` or harness tuple):
  - `:timeout_ms` - Max execution timeout per inline command (default: 15_000).
  - `:max_output_bytes` - Output truncation threshold (default: 8_192).
  """

  use SuperPi.Extension
  require Logger

  @default_max_output_bytes 8_192
  @default_command_timeout_ms 15_000

  def id, do: "inline_bash"
  def name, do: "Inline Bash Expander"
  def description, do: "Expands !{command} patterns in prompts with live command output"

  @impl true
  def on_input(text, ctx) when is_binary(text) do
    trimmed = String.trim_leading(text)

    # Preserve whole-line bash escapes (starts with '!' but not '!{')
    if String.starts_with?(trimmed, "!") and not String.starts_with?(trimmed, "!{") do
      :continue
    else
      if String.contains?(text, "!{") do
        ws = Map.get(ctx, :workspace_root, File.cwd!())
        config = Map.get(ctx, :config, [])
        timeout_ms = get_config(config, :timeout_ms, @default_command_timeout_ms)
        max_bytes = get_config(config, :max_output_bytes, @default_max_output_bytes)

        transformed = expand_inline_patterns(text, ws, timeout_ms, max_bytes)
        {:transform, transformed, []}
      else
        :continue
      end
    end
  end

  def on_input(_text, _ctx), do: :continue

  defp expand_inline_patterns(text, ws, timeout_ms, max_bytes) do
    do_expand(text, 0, "", ws, timeout_ms, max_bytes)
  end

  defp do_expand(text, pos, acc, ws, timeout_ms, max_bytes) do
    case :binary.match(text, "!{", [{:scope, {pos, byte_size(text) - pos}}]) do
      :nomatch ->
        acc <> binary_part(text, pos, byte_size(text) - pos)

      {match_pos, 2} ->
        prefix = binary_part(text, pos, match_pos - pos)

        case find_closing_brace(text, match_pos + 2, 1) do
          {:ok, end_pos} ->
            cmd = binary_part(text, match_pos + 2, end_pos - match_pos - 2)
            trimmed_cmd = String.trim(cmd)
            replacement = execute_inline_command(trimmed_cmd, ws, timeout_ms, max_bytes)
            do_expand(text, end_pos + 1, acc <> prefix <> replacement, ws, timeout_ms, max_bytes)

          :error ->
            do_expand(text, match_pos + 2, acc <> prefix <> "!{", ws, timeout_ms, max_bytes)
        end
    end
  end

  defp find_closing_brace(text, pos, depth) when pos < byte_size(text) do
    case :binary.at(text, pos) do
      ?{ -> find_closing_brace(text, pos + 1, depth + 1)
      ?} when depth == 1 -> {:ok, pos}
      ?} -> find_closing_brace(text, pos + 1, depth - 1)
      _ -> find_closing_brace(text, pos + 1, depth)
    end
  end

  defp find_closing_brace(_text, _pos, _depth), do: :error

  defp execute_inline_command(cmd, ws, timeout_ms, max_bytes) do
    Logger.debug("[InlineBash] Expanding: #{cmd} in #{ws}")

    try do
      port =
        Port.open(
          {:spawn_executable, System.find_executable("sh")},
          [:binary, :exit_status, :stderr_to_stdout, args: ["-c", cmd], cd: ws]
        )

      {:os_pid, sh_pid} = Port.info(port, :os_pid)
      deadline = System.monotonic_time(:millisecond) + timeout_ms

      case collect_port_output(port, sh_pid, deadline, "") do
        {:ok, out, 0} ->
          truncate_output(String.trim(out), max_bytes)

        {:ok, err, exit_code} ->
          "[Command '#{cmd}' failed with code #{exit_code}: #{truncate_output(String.trim(err), max_bytes)}]"

        :timeout ->
          "[Command '#{cmd}' timed out after #{timeout_ms}ms]"
      end
    rescue
      e ->
        "[Command '#{cmd}' error: #{Exception.message(e)}]"
    end
  end

  defp collect_port_output(port, sh_pid, deadline, acc) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        collect_port_output(port, sh_pid, deadline, acc <> data)

      {^port, {:exit_status, status}} ->
        {:ok, acc, status}
    after
      remaining ->
        kill_os_process(sh_pid, port)
        :timeout
    end
  end

  defp kill_os_process(sh_pid, port) do
    System.cmd("pkill", ["-KILL", "-P", to_string(sh_pid)], stderr_to_stdout: true)
    System.cmd("kill", ["-KILL", to_string(sh_pid)], stderr_to_stdout: true)

    try do
      Port.close(port)
    rescue
      _ -> :ok
    end
  end

  defp truncate_output(out, max_bytes) when byte_size(out) > max_bytes do
    trimmed = safe_slice_utf8(out, max_bytes)
    trimmed <> "\n... [truncated #{byte_size(out) - byte_size(trimmed)} bytes]"
  end

  defp truncate_output(out, _max_bytes), do: out

  defp safe_slice_utf8(binary, bytes) do
    slice = binary_part(binary, 0, bytes)
    clean_utf8_tail(slice)
  end

  defp clean_utf8_tail(slice) do
    if String.valid?(slice) do
      slice
    else
      clean_utf8_tail(binary_part(slice, 0, byte_size(slice) - 1))
    end
  end

  defp get_config(config, key, default) when is_map(config) do
    case Map.fetch(config, key) do
      {:ok, val} ->
        val

      :error ->
        case Map.fetch(config, to_string(key)) do
          {:ok, val} -> val
          :error -> default
        end
    end
  end

  defp get_config(config, key, default) when is_list(config) do
    Keyword.get(config, key, default)
  end

  defp get_config(_config, _key, default), do: default
end
