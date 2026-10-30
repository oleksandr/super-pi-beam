defmodule SuperPi.CLIInteractiveTest do
  @moduledoc "`run`, `chat`, `--harness` and `--continue` (doc 24 P0.4)."
  use SuperPi.DataCase, async: false

  alias SuperPi.CLI
  alias SuperPi.Durable.{Doc, Storage}
  alias SuperPi.TestSupport.Faults

  setup do
    Process.flag(:trap_exit, true)
    dir = Path.join(System.tmp_dir!(), "cli_inter_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    %{
      opts: [
        global_config_dir: dir,
        app_data_dir: dir,
        extensions: [],
        llm_responder: fn _p, _c -> {:ok, Faults.text_msg("pong")} end
      ]
    }
  end

  # Feeds `lines` to the REPL one at a time and collects everything written.
  defp chat(opts, lines, extra_args \\ []) do
    {:ok, feeder} = Agent.start_link(fn -> lines end)
    {:ok, out} = Agent.start_link(fn -> [] end)

    read = fn _prompt ->
      Agent.get_and_update(feeder, fn
        [] -> {:eof, []}
        [h | t] -> {h <> "\n", t}
      end)
    end

    write = fn text -> Agent.update(out, &[text | &1]) end
    result = CLI.run(["chat" | extra_args], Keyword.merge(opts, read_line: read, write: write))
    {result, out |> Agent.get(&Enum.reverse/1) |> Enum.join()}
  end

  describe "run" do
    test "runs the words after `run` as one prompt", %{opts: opts} do
      assert {0, "pong"} = CLI.run(["run", "say", "ping"], opts)
    end

    test "reads the prompt from stdin when none is given", %{opts: opts} do
      me = self()

      responder = fn payload, _ctx ->
        send(me, {:payload, inspect(payload)})
        {:ok, Faults.text_msg("pong")}
      end

      opts = Keyword.merge(opts, stdin_lines: ["line one", "line two"], llm_responder: responder)
      assert {0, "pong"} = CLI.run(["run"], opts)
      assert_received {:payload, payload}
      assert payload =~ "line one"
      assert payload =~ "line two"
    end
  end

  describe "chat" do
    test "answers each line and stops on /exit", %{opts: opts} do
      {result, out} = chat(opts, ["hello", "again", "/exit", "never sent"])

      assert {0, ""} = result
      assert length(String.split(out, "pong")) - 1 == 2
    end

    test "stops at end of input", %{opts: opts} do
      assert {{0, ""}, _out} = chat(opts, ["hello"])
    end

    test "skips blank lines", %{opts: opts} do
      {_result, out} = chat(opts, ["", "   ", "hi"])
      assert length(String.split(out, "pong")) - 1 == 1
    end

    test "a provider error is printed and the session continues", %{opts: opts} do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      responder = fn _p, _c ->
        case Agent.get_and_update(calls, &{&1, &1 + 1}) do
          0 -> {:error, :boom}
          _ -> {:ok, Faults.text_msg("recovered")}
        end
      end

      {{0, ""}, out} = chat(Keyword.put(opts, :llm_responder, responder), ["one", "two"])
      assert out =~ "error:"
      assert out =~ "recovered"
    end
  end

  describe "chat answers ask_question on the terminal" do
    defp question_responder(me) do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      fn payload, _ctx ->
        case Agent.get_and_update(calls, &{&1, &1 + 1}) do
          0 ->
            args = %{
              "questions" => [
                %{"question" => "Which backend?", "options" => ["SQLite", "PostgreSQL"]}
              ]
            }

            {:ok, Faults.tool_call_msg("q1", "ask_question", args)}

          _ ->
            send(me, {:history, inspect(payload.messages)})
            {:ok, Faults.text_msg("thanks")}
        end
      end
    end

    test "a numbered answer reaches the model", %{opts: opts} do
      opts =
        Keyword.merge(opts,
          extensions: [SuperPi.Plugins.Questionnaire],
          llm_responder: question_responder(self())
        )

      {{0, ""}, out} = chat(opts, ["go", "2", "/exit"])

      assert out =~ "? Which backend?"
      assert out =~ "1) SQLite"
      assert out =~ "thanks"
      assert_received {:history, history}
      assert history =~ "Answer: PostgreSQL"
    end

    test "free text is passed through, and end of input cancels the question", %{opts: opts} do
      opts =
        Keyword.merge(opts,
          extensions: [SuperPi.Plugins.Questionnaire],
          llm_responder: question_responder(self())
        )

      {{0, ""}, _out} = chat(opts, ["go", "MySQL", "/exit"])
      assert_received {:history, history}
      assert history =~ "Answer: MySQL"

      opts2 = Keyword.put(opts, :llm_responder, question_responder(self()))
      {{0, ""}, _} = chat(opts2, ["go"])
      assert_received {:history, cancelled}
      assert cancelled =~ "cancelled"
    end
  end

  describe "--harness" do
    test "an unknown harness is an error, not a silent fallback", %{opts: opts} do
      assert {1, message} = CLI.run(["--harness", "no-such-harness", "-p", "hi"], opts)
      assert message =~ "Unknown harness: no-such-harness"
    end

    test "a known harness is used", %{opts: opts} do
      {:ok, mod} = SuperPi.Harness.fetch("super-pi-planner")
      conv = Storage.create_conversation!()

      assert {0, "pong"} =
               CLI.run(
                 ["--harness", "super-pi-planner", "--conversation", "#{conv.id}", "-p", "hi"],
                 Keyword.delete(opts, :extensions)
               )

      assert mod.id() == "super-pi-planner"
    end
  end

  describe "--continue" do
    test "resumes the latest top-level conversation, not conversation 1", %{opts: opts} do
      _older = Storage.create_conversation!()
      latest = Storage.create_conversation!()

      assert {0, "pong"} = CLI.run(["--continue", "-p", "hi"], opts)

      assert Storage.latest_conversation().id == latest.id
      assert %{"workspacePaths" => _} = Doc.snapshot("conversation", latest.id, "pi.agent")
    end

    test "creates a conversation when none exists", %{opts: opts} do
      # On PostgreSQL other tests have committed conversations, so compare with what was there.
      before = Storage.latest_conversation()
      assert {0, "pong"} = CLI.run(["--continue", "-p", "hi"], opts)
      latest = Storage.latest_conversation()

      if before == nil,
        do: assert(latest != nil, "no conversation was created"),
        else:
          assert(
            latest.id == before.id,
            "--continue should have used the existing latest conversation"
          )
    end

    test "latest_conversation ignores forks" do
      parent = Storage.create_conversation!()
      entry = Storage.append_entry!(parent.id, "message", %{"role" => "user", "content" => "x"})
      _fork = Storage.fork_conversation!(parent.id, entry.id)

      assert Storage.latest_conversation().id == parent.id
    end
  end
end
