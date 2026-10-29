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

  @pattern ~r/!\{([^}]+)\}/
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
      if Regex.match?(@pattern, text) do
        ws = Map.get(ctx, :workspace_root, File.cwd!())
        config = Map.get(ctx, :config, [])
        timeout_ms = Keyword.get(config, :timeout_ms, @default_command_timeout_ms)
        max_bytes = Keyword.get(config, :max_output_bytes, @default_max_output_bytes)

        transformed = expand_inline_patterns(text, ws, timeout_ms, max_bytes)
        {:transform, transformed, []}
      else
        :continue
      end
    end
  end

  def on_input(_text, _ctx), do: :continue

  defp expand_inline_patterns(text, ws, timeout_ms, max_bytes) do
    Regex.replace(@pattern, text, fn _full, cmd ->
      trimmed_cmd = String.trim(cmd)
      execute_inline_command(trimmed_cmd, ws, timeout_ms, max_bytes)
    end)
  end

  defp execute_inline_command(cmd, ws, timeout_ms, max_bytes) do
    Logger.debug("[InlineBash] Expanding: #{cmd} in #{ws}")

    try do
      task =
        Task.async(fn ->
          System.cmd("sh", ["-c", cmd], cd: ws, stderr_to_stdout: true)
        end)

      case Task.yield(task, timeout_ms) || Task.shutdown(task) do
        {:ok, {out, 0}} ->
          truncate_output(String.trim(out), max_bytes)

        {:ok, {err, exit_code}} ->
          "[Command '#{cmd}' failed with code #{exit_code}: #{truncate_output(String.trim(err), max_bytes)}]"

        nil ->
          "[Command '#{cmd}' timed out after #{timeout_ms}ms]"
      end
    rescue
      e ->
        "[Command '#{cmd}' error: #{Exception.message(e)}]"
    end
  end

  defp truncate_output(out, max_bytes) when byte_size(out) > max_bytes do
    binary_part(out, 0, max_bytes) <> "\n... [truncated #{byte_size(out) - max_bytes} bytes]"
  end

  defp truncate_output(out, _max_bytes), do: out
end
