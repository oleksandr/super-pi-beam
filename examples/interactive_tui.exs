# Interactive Owl TUI powered by live Google Gemini (`examples/interactive_tui.exs`)
#
# Run with:
#   cd /home/oleksandr/Projects/super-pi-beam
#   mise exec -- mix run examples/interactive_tui.exs

alias SuperPi.Conversation.Machine
alias SuperPi.Durable.Storage
alias SuperPi.Tools
alias SuperPi.TUI.Owl, as: OwlTUI

conv =
  Storage.create_conversation!(
    agent: %{
      "model" => "gemini-3-flash-preview",
      "systemSections" => [
        %{
          "id" => "core",
          "content" =>
            "You are Super-Pi-BEAM, a durable coding agent running on Erlang/OTP 28 and Elixir 1.20. Use your tools (`read`, `write`, `edit`, `grep`, `find`, `ls`, `bash`, `tool_search`) whenever helpful."
        }
      ],
      "tools" => Tools.active_llm_tools()
    }
  )

{:ok, pid} = Machine.start_link(conversation_id: conv.id)

IO.puts(OwlTUI.render_status_bar(conv.id))
IO.puts("Commands: /status | /context | /compact | /quit\n")

loop = fn loop_fn ->
  case IO.gets("super-pi> ") do
    :eof ->
      :ok

    {:error, _} ->
      :ok

    line ->
      trimmed = String.trim(line)

      cond do
        trimmed in ["/quit", "/exit"] ->
          IO.puts("Bye!")

        trimmed == "" ->
          loop_fn.(loop_fn)

        true ->
          out = OwlTUI.handle_line(conv.id, pid, trimmed)
          IO.puts("\n" <> out <> "\n")
          loop_fn.(loop_fn)
      end
  end
end

loop.(loop)
GenServer.stop(pid)
