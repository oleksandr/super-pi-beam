# Live Google Gemini End-to-End Agentic Demo (`examples/gemini_live_demo.exs`)
#
# Uses your `GEMINI_API_KEY` from the environment to run a multi-turn agentic session
# on `gemini-2.5-flash` with:
# - Real built-in 3-channel tools (`read`, `write`, `edit`, `grep`, `find`, `ls`, `bash`)
# - Durable SQLite persistence (`SuperPi.Durable.Storage`)
# - Normative 10-rule context derivation (`SuperPi.Durable.Context`)
# - `:gen_statem` turn orchestration (`SuperPi.Conversation.Machine`)
# - Owl ANSI terminal formatting (`SuperPi.TUI.Owl`)
#
# Run with:
#   cd path/to/super-pi-beam
#   mise exec -- mix run examples/gemini_live_demo.exs

alias SuperPi.Conversation.Machine
alias SuperPi.Durable.{Context, Storage}
alias SuperPi.Tools
alias SuperPi.TUI.Owl, as: OwlTUI

unless SuperPi.AI.GeminiClient.configured?() do
  IO.puts(:stderr, "ERROR: GEMINI_API_KEY is not set in the environment.")
  System.halt(1)
end

conv =
  Storage.create_conversation!(
    agent: %{
      "model" => "gemini-3-flash-preview",
      "systemSections" => [
        %{
          "id" => "core",
          "content" =>
            "You are Super-Pi-BEAM, a durable coding agent running on Erlang/OTP 28 and Elixir 1.20. Use your tools when asked to inspect files."
        }
      ],
      "tools" => Tools.active_llm_tools()
    }
  )

{:ok, pid} = Machine.start_link(conversation_id: conv.id)

IO.puts(OwlTUI.render_status_bar(conv.id))

prompt =
  "Use the `read` tool to read `mix.exs` (limit 25 lines) and tell me the Elixir app name, version, and 3 key dependencies you see."

IO.puts("\nUser > #{prompt}\n")

case Machine.submit(pid, prompt, timeout: 60_000) do
  {:ok, assistant_msg} ->
    IO.puts("Assistant (Gemini 3 Flash Preview) >")
    IO.puts(OwlTUI.render_assistant_message(assistant_msg))

    derived = Context.derive(conv.id)
    IO.puts("\n" <> OwlTUI.render_status_bar(conv.id))
    IO.puts("==> Durable entries recorded in SQLite: #{length(derived.messages)} messages in derived context.")

  {:error, reason} ->
    IO.puts(:stderr, "Error from Gemini: #{inspect(reason)}")
end

GenServer.stop(pid)
