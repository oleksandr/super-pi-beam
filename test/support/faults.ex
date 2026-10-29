defmodule SuperPi.TestSupport.Faults do
  @moduledoc """
  Fault-injection helpers for conversation machine tests: responders, tool
  executors and extensions that raise, block, or request termination on demand.
  """

  def text_msg(text), do: %{"role" => "assistant", "content" => [%{"type" => "text", "text" => text}]}

  def tool_call_msg(id, name, args) do
    %{
      "role" => "assistant",
      "content" => [%{"type" => "tool_call", "id" => id, "name" => name, "arguments" => args}]
    }
  end

  @doc "Calls `tool_name` on the first turn, then answers `final_text` once a tool result exists."
  def tool_then_text_responder(tool_name, args, final_text) do
    fn payload, _ctx ->
      if Enum.any?(payload.messages, &(&1["role"] == "tool")) do
        {:ok, text_msg(final_text)}
      else
        {:ok, tool_call_msg("call_1", tool_name, args)}
      end
    end
  end

  @doc "Raises inside the responder."
  def raising_responder(message \\ "injected responder fault") do
    fn _payload, _ctx -> raise message end
  end

  @doc """
  Tells `test_pid` `{:responder_started, pid}`, where `pid` is the process that
  runs the responder, then blocks until that process receives `:release`.
  Works whether the responder runs in the machine or in a helper task.
  """
  def blocking_responder(test_pid, text) do
    fn _payload, _ctx ->
      send(test_pid, {:responder_started, self()})

      receive do
        :release -> {:ok, text_msg(text)}
      after
        15_000 -> {:error, :blocking_responder_timeout}
      end
    end
  end

  @doc "Tool executor that asks the machine to terminate the run."
  def terminating_tool_executor(_name, _args, _ctx) do
    %{"output" => "done", "details" => %{}, "control" => %{"terminate" => true}}
  end

  def plain_tool_executor(_name, _args, _ctx) do
    %{"output" => "ok", "details" => %{}}
  end

  defmodule RaiseBeforeTool do
    use SuperPi.Extension

    @impl true
    def before_tool(_name, _args, _ctx), do: raise("injected before_tool fault")
  end

  defmodule RaiseAfterResponse do
    use SuperPi.Extension

    @impl true
    def after_response(_msg, _ctx), do: raise("injected after_response fault")
  end

  defmodule TerminateAfterTools do
    use SuperPi.Extension

    @impl true
    def after_tools(_results, _ctx), do: :terminate
  end

  defmodule BadAfterToolsReturn do
    use SuperPi.Extension

    @impl true
    def after_tools(_results, _ctx), do: {:unexpected, :shape}
  end
end
