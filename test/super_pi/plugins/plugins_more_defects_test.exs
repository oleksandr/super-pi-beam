defmodule SuperPi.Plugins.PluginsMoreDefectsTest do
  @moduledoc """
  Regression tests for further plugin / TUI / journal defects from the code
  review. Every test is expected to FAIL on the current code and pass once the
  finding is fixed.

  Run only these:  mix test --only known_bug
  Skip these:      mix test --exclude known_bug
  """
  use SuperPi.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias SuperPi.CodeMode.Journal
  alias SuperPi.Conversation.Machine
  alias SuperPi.Durable.{Doc, Storage}
  alias SuperPi.Gateway.Router
  alias SuperPi.Plugins.{ConfirmDestructive, CustomCompaction, Handoff, JevRouter, Todo}
  alias SuperPi.TUI.Owl, as: OwlTUI


  setup do
    SuperPi.Tools.ensure_catalog_ets!()
    :ok
  end

  defp attempt(fun) do
    {:ok, fun.()}
  rescue
    e -> {:raised, e}
  end

  defmodule HandleAll do
    use SuperPi.Extension

    @impl true
    def on_input(_text, _ctx), do: :handled
  end

  defmodule CancelCompact do
    use SuperPi.Extension

    @impl true
    def before_compact(_req, _ctx), do: :cancel
  end

  defp machine(opts) do
    conv = Storage.create_conversation!()
    {:ok, pid} = Machine.start_link([conversation_id: conv.id] ++ opts)
    {conv.id, pid}
  end

  describe "code_mode/journal.ex (:29-52)" do
    test "same call index with different args does not return the cached result" do
      task_id = 4_001
      {:executed, _} = Journal.execute_journaled_tool(task_id, 0, "read", %{"path" => "a"}, fn _, _ -> "A" end)

      result = Journal.execute_journaled_tool(task_id, 0, "read", %{"path" => "b"}, fn _, _ -> "B" end)

      assert result == {:executed, "B"}, "got stale cached result for different args: #{inspect(result)}"
    end

    test "a tool-name mismatch at a recorded index is not silently overwritten" do
      task_id = 4_002
      {:executed, _} = Journal.execute_journaled_tool(task_id, 0, "read", %{}, fn _, _ -> "R" end)

      result = attempt(fn -> Journal.execute_journaled_tool(task_id, 0, "write", %{}, fn _, _ -> "W" end) end)

      refute match?({:ok, {:executed, _}}, result),
             "journal diverged from the recorded script but silently re-executed and overwrote the step"
    end

    test "a replayed result equals the fresh result (JSON round trip after restart)" do
      task_id = 4_003
      fresh_value = %{status: :ok, items: [1, 2]}

      {:executed, fresh} = Journal.execute_journaled_tool(task_id, 0, "t", %{}, fn _, _ -> fresh_value end)

      # Simulate a node restart: the ETS cache is gone, the DB copy is JSON.
      :ets.delete_all_objects(:super_pi_doc_cache)
      {:replayed, replayed} = Journal.execute_journaled_tool(task_id, 0, "t", %{}, fn _, _ -> flunk("re-executed") end)

      assert fresh == replayed, "fresh #{inspect(fresh)} differs from replayed #{inspect(replayed)}"
    end

    test "a non-JSON result does not crash after the side effect already ran" do
      task_id = 4_004

      result =
        attempt(fn ->
          Journal.execute_journaled_tool(task_id, 0, "t", %{}, fn _, _ -> {:ok, "tuple result"} end)
        end)

      assert match?({:ok, {:executed, _}}, result),
             "journal write raised after the tool ran, so a retry re-executes the side effect: #{inspect(result)}"
    end
  end

  describe "tui/owl.ex handle_line (:67-86)" do
    test "/compact cancelled by an extension does not crash" do
      {conv_id, pid} = machine(extensions: [CancelCompact])
      assert {:ok, out} = attempt(fn -> OwlTUI.handle_line(conv_id, pid, "/compact") end)
      assert is_binary(out)
    end

    test "input handled by an extension does not crash" do
      {conv_id, pid} = machine(extensions: [HandleAll])
      assert {:ok, out} = attempt(fn -> OwlTUI.handle_line(conv_id, pid, "hello") end)
      assert is_binary(out)
    end

    test "a failing responder returns an error line instead of crashing" do
      {conv_id, pid} = machine(llm_responder: fn _payload, _ctx -> {:error, :boom} end)
      assert {:ok, out} = attempt(fn -> OwlTUI.handle_line(conv_id, pid, "hello") end)
      assert is_binary(out)
    end

    test "assistant message with string content renders" do
      assert {:ok, out} = attempt(fn -> OwlTUI.render_assistant_message(%{"role" => "assistant", "content" => "hi"}) end)
      assert out =~ "hi"
    end

    test "/quit is handled locally and not sent to the LLM" do
      {conv_id, pid} = machine([])
      out = OwlTUI.handle_line(conv_id, pid, "/quit")
      refute out =~ "Echo: /quit", "documented /quit falls through to the model"
    end

    test "/fork is handled locally and not sent to the LLM" do
      {conv_id, pid} = machine([])
      out = OwlTUI.handle_line(conv_id, pid, "/fork")
      refute out =~ "Echo: /fork", "documented /fork falls through to the model"
    end
  end

  describe "plugins/jev_router.ex (:37-56)" do
    test "does not override the selected model when no Gemini key is configured" do
      refute SuperPi.AI.GeminiClient.configured?(), "precondition: no Gemini configured in test"

      derived = %{model: "claude-sonnet-4-5", messages: []}
      {:ok, out} = JevRouter.before_request(derived, %{})

      assert out.model == "claude-sonnet-4-5", "model forced to #{out.model}"
    end
  end

  describe "plugins/custom_compaction.ex (:39-41)" do
    # Shapes persisted by machine.ex: assistant tool_call blocks carry the
    # arguments, the tool entry has name/content/details but no "arguments".
    defp entries do
      [
        %{
          id: 1,
          kind: "pi.message",
          data: %{
            "role" => "assistant",
            "content" => [
              %{"type" => "tool_call", "id" => "c1", "name" => "write", "arguments" => %{"path" => "lib/changed.ex"}}
            ]
          }
        },
        %{
          id: 2,
          kind: "pi.message",
          data: %{
            "role" => "tool",
            "tool_call_id" => "c1",
            "name" => "write",
            "content" => "ok",
            "details" => nil
          }
        }
      ]
    end

    test "summary lists files modified by write/edit tool calls" do
      assert CustomCompaction.build_milestone_summary(entries()) =~ "lib/changed.ex"
    end

    test "a caller-supplied opts[:summary] is honoured" do
      assert {:compacted, "my summary", _} =
               CustomCompaction.before_compact(%{entries: entries(), opts: [summary: "my summary"]}, %{})
    end
  end

  describe "plugins/handoff.ex (:74-90)" do
    test "child session inherits the parent's model" do
      parent = Storage.create_conversation!(agent: %{"model" => "parent-model"})

      res = Handoff.wrap_tool("handoff", %{"goal" => "g", "summary" => "s"}, fn _ -> %{} end, %{conversation_id: parent.id})
      child_id = res["structured_output"]["child_conversation_id"]

      agent = Doc.snapshot("conversation", child_id, "pi.agent")
      assert agent["model"] == "parent-model", "child pi.agent has no parent model: #{inspect(Map.keys(agent))}"
    end
  end

  describe "before_agent_start with \"tools\" => nil" do
    plugins = [
      SuperPi.Plugins.Handoff,
      SuperPi.Plugins.Questionnaire,
      SuperPi.Plugins.PromptCustomizer,
      SuperPi.Plugins.Subagent,
      SuperPi.Plugins.StructuredOutput,
      SuperPi.Plugins.Todo
    ]

    for plugin <- plugins do
      test "#{inspect(plugin)} tolerates a nil tools list" do
        assert {:ok, {:ok, _cfg}} = attempt(fn -> unquote(plugin).before_agent_start(%{"tools" => nil}, %{}) end)
      end
    end
  end

  describe "plugins/confirm_destructive.ex (:30)" do
    test "block message does not promise a confirmation step that does not exist" do
      assert {:block, msg} = ConfirmDestructive.before_tool("bash", %{"command" => "rm -rf /tmp/x"}, %{config: []})
      refute msg =~ ~r/confirmation required/i
    end
  end

  describe "plugins/inline_bash.ex via the gateway" do
    test "!{cmd} in a chat completion is not executed on the host" do
      payload = %{
        "model" => "super-pi-interactive",
        "messages" => [%{"role" => "user", "content" => "!{echo PWNED_$((40+2))}"}],
        "stream" => false
      }

      conn =
        conn(:post, "/v1/chat/completions", Jason.encode!(payload))
        |> put_req_header("content-type", "application/json")
        |> Router.call(Router.init([]))

      refute conn.resp_body =~ "PWNED_42", "remote user text executed a shell command on the host"
    end
  end

  describe "plugins/todo.ex (:58,94,122)" do
    test "a failed save is reported as an error, not success" do
      conv = Storage.create_conversation!()

      # Invalid UTF-8 cannot be JSON-encoded, so persisting the todo list fails.
      res = Todo.wrap_tool("todo", %{"action" => "add", "text" => <<255, 254>>}, fn _ -> %{} end, %{conversation_id: conv.id})

      assert res["is_error"] == true, "tool reported success although nothing was persisted"
    end
  end
end
