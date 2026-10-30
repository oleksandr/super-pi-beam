defmodule SuperPi.ReviewFixesTest do
  @moduledoc """
  Regression tests for the `/code-review high` findings of 2026-10-30 (Kanban Tasks 49 to 58).
  Each test failed on the code before its fix.
  """
  use SuperPi.DataCase, async: false

  alias SuperPi.AI.GeminiClient
  alias SuperPi.AI.Providers.{Anthropic, OpenAI}
  alias SuperPi.Conversation.Machine
  alias SuperPi.Durable.{Context, Storage, TaskEngine}
  alias SuperPi.Durable.Schemas.Task, as: TaskSchema
  alias SuperPi.TestSupport.Faults

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  defp submit(pid, text, opts \\ []) do
    Machine.submit(pid, text, Keyword.put_new(opts, :timeout, 10_000))
  catch
    :exit, reason -> {:exit, reason}
  end

  defp eventually(fun, tries \\ 300) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never held")
      true ->
        Process.sleep(10)
        eventually(fun, tries - 1)
    end
  end

  defp machine_state(pid), do: pid |> Machine.get_state() |> elem(0)

  defp generation_tasks(conv_id) do
    Repo.all(from t in TaskSchema, where: t.conversation_id == ^conv_id and t.kind == "pi.generation", order_by: t.id)
  end

  # The rule both providers enforce: each assistant tool call has one result, and the results come
  # directly after the assistant message.
  defp assert_tool_pairs(messages) do
    messages
    |> Enum.with_index()
    |> Enum.each(fn
      {%{"role" => "assistant", "content" => content}, i} when is_list(content) ->
        ids = for %{"type" => "tool_call", "id" => id} <- content, do: id
        following = messages |> Enum.drop(i + 1) |> Enum.take(length(ids))

        assert Enum.map(following, &{&1["role"], &1["tool_call_id"]}) == Enum.map(ids, &{"tool", &1}),
               "tool calls #{inspect(ids)} not followed by their results: #{inspect(Enum.map(following, &Map.take(&1, ["role", "tool_call_id"])))}"

      _ ->
        :ok
    end)
  end

  defp two_tool_calls do
    %{
      "role" => "assistant",
      "content" => [
        %{"type" => "tool_call", "id" => "call_a", "name" => "t", "arguments" => %{"n" => "a"}},
        %{"type" => "tool_call", "id" => "call_b", "name" => "t", "arguments" => %{"n" => "b"}}
      ]
    }
  end

  defp user_texts(messages), do: for(%{"role" => "user", "content" => [%{"text" => t} | _]} <- messages, do: t)

  @todo_schema %{
    "type" => "object",
    "properties" => %{"action" => %{"type" => "string", "enum" => ["list", "add"]}},
    "required" => ["action"]
  }

  @mcp_schema %{
    "type" => "object",
    "properties" => %{"city" => %{"type" => ["string", "null"]}},
    "required" => ["city"],
    "additionalProperties" => false
  }

  describe "Task 49: tool parameter schemas reach the provider" do
    test "plugin and MCP tool schemas survive context derivation and go into every request body" do
      conv = Storage.create_conversation!()

      mcp =
        SuperPi.Tools.register_tool!(
          %{"name" => "mcp__weather__forecast", "description" => "Forecast", "input_schema" => @mcp_schema},
          :hidden
        )

      assert mcp["parameters"] == @mcp_schema
      refute Map.has_key?(mcp, "input_schema")

      tools = [
        %{"name" => "todo", "description" => "Checklist", "parameters" => @todo_schema},
        # A stored tool from an MCP server registered before the catalog used one key.
        %{"name" => "mcp__weather__old", "description" => "Old", "input_schema" => @mcp_schema},
        %{"name" => "read", "description" => "Read a file"}
      ]

      Context.ensure_system_state!(conv.id, [%{"id" => "core", "content" => "x"}], tools)
      derived = Context.derive(conv.id)
      by_name = Map.new(derived.tools, &{&1["name"], &1})

      assert by_name["todo"]["parameters"] == @todo_schema
      assert by_name["mcp__weather__old"]["parameters"] == @mcp_schema
      assert by_name["read"]["parameters"]["required"] == ["path"]

      payload = %{model: "m", system_sections: derived.system_sections, messages: [], tools: derived.tools}

      anthropic = Map.new(Anthropic.build_body(payload)["tools"], &{&1["name"], &1["input_schema"]})
      assert anthropic["todo"] == @todo_schema
      assert anthropic["mcp__weather__old"] == @mcp_schema

      openai = Map.new(OpenAI.build_body(payload)["tools"], &{&1["function"]["name"], &1["function"]["parameters"]})
      assert openai["todo"] == @todo_schema
      assert openai["mcp__weather__old"] == @mcp_schema

      [%{"functionDeclarations" => decls}] = GeminiClient.build_gemini_body(payload)["tools"]
      gemini = Map.new(decls, &{&1["name"], &1["parameters"]})

      assert gemini["todo"] == %{
               "type" => "OBJECT",
               "properties" => %{"action" => %{"type" => "STRING", "enum" => ["list", "add"]}},
               "required" => ["action"]
             }

      assert gemini["mcp__weather__old"] == %{
               "type" => "OBJECT",
               "properties" => %{"city" => %{"type" => "STRING", "nullable" => true}},
               "required" => ["city"]
             }

      # The Gemini schema for a built-in tool comes from the same table as the other providers.
      assert gemini["read"]["required"] == ["path"]
    end
  end

  describe "Task 50: tool call and tool result pairs survive steer and cancel" do
    test "steer while the model streams a tool call: the calls get skipped results before the steer text" do
      conv = Storage.create_conversation!()
      test_pid = self()
      counter = :counters.new(1, [])

      responder = fn _payload, _ctx ->
        :counters.add(counter, 1, 1)

        if :counters.get(counter, 1) == 1 do
          send(test_pid, {:streaming, self()})

          receive do
            :release -> {:ok, two_tool_calls()}
          end
        else
          {:ok, Faults.text_msg("after steer")}
        end
      end

      executor = fn _n, _a, _c ->
        send(test_pid, :tool_ran)
        %{"output" => "ran"}
      end
      {:ok, pid} = Machine.start_link(conversation_id: conv.id, llm_responder: responder, tool_executor: executor)

      turn = Task.async(fn -> submit(pid, "start") end)
      assert_receive {:streaming, llm}, 5_000
      assert {:ok, :steered} = submit(pid, "STEER", mode: :steer)
      send(llm, :release)
      assert {:ok, _} = Task.await(turn, 10_000)

      refute_received :tool_ran
      messages = Context.derive(conv.id).messages
      assert_tool_pairs(messages)
      assert user_texts(messages) == ["start", "STEER"]
      assert messages |> Enum.find_index(&(&1["role"] == "assistant")) < Enum.find_index(messages, &(&1["content"] == [%{"type" => "text", "text" => "STEER"}]))
    end

    test "steer during a tool batch: the skipped results come before the steer text" do
      conv = Storage.create_conversation!()
      test_pid = self()

      responder = fn payload, _ctx ->
        if Enum.any?(payload.messages, &(&1["role"] == "tool")), do: {:ok, Faults.text_msg("done")}, else: {:ok, two_tool_calls()}
      end

      executor = fn _name, %{"n" => n}, _ctx ->
        send(test_pid, {:executing, n, self()})
        if n == "a", do: receive(do: (:release -> :ok))
        %{"output" => "ok-#{n}"}
      end

      {:ok, pid} = Machine.start_link(conversation_id: conv.id, llm_responder: responder, tool_executor: executor)
      turn = Task.async(fn -> submit(pid, "go") end)
      assert_receive {:executing, "a", tool}, 5_000

      # The machine answers while the tool runs.
      assert {:ok, :steered} = submit(pid, "STEER", mode: :steer, timeout: 1_000)
      send(tool, :release)
      assert {:ok, _} = Task.await(turn, 10_000)

      refute_received {:executing, "b", _}
      messages = Context.derive(conv.id).messages
      assert_tool_pairs(messages)
      assert user_texts(messages) == ["go", "STEER"]
    end

    test "cancel during a tool batch: the running and the queued calls get results, the task is cancelled" do
      conv = Storage.create_conversation!()
      test_pid = self()

      executor = fn _name, %{"n" => n}, _ctx ->
        send(test_pid, {:executing, n})
        Process.sleep(30_000)
      end

      {:ok, pid} = Machine.start_link(conversation_id: conv.id, llm_responder: fn _p, _c -> {:ok, two_tool_calls()} end, tool_executor: executor)
      turn = Task.async(fn -> submit(pid, "go") end)
      assert_receive {:executing, "a"}, 5_000

      Machine.cancel(pid)
      assert {:error, :cancelled} = Task.await(turn, 5_000)
      assert machine_state(pid) == :idle

      messages = Context.derive(conv.id).messages
      assert_tool_pairs(messages)
      assert [%{status: "cancelled"}] = generation_tasks(conv.id)
    end

    test "a history stored in the old, broken order is repaired when the context is derived" do
      conv = Storage.create_conversation!()
      append = &Storage.append_entry!(conv.id, "pi.message", &1)

      append.(%{"role" => "user", "content" => [%{"type" => "text", "text" => "go"}]})
      append.(two_tool_calls() |> Map.update!("content", &(&1 ++ [%{"type" => "tool_call", "id" => "call_c", "name" => "t", "arguments" => %{}}])))
      append.(%{"role" => "tool", "tool_call_id" => "call_a", "name" => "t", "content" => "ok-a"})
      append.(%{"role" => "user", "content" => [%{"type" => "text", "text" => "STEER"}], "steer" => true})
      append.(%{"role" => "tool", "tool_call_id" => "call_b", "name" => "t", "content" => "skipped", "is_error" => true})

      messages = Context.derive(conv.id).messages
      assert_tool_pairs(messages)
      assert Enum.map(messages, &(&1["tool_call_id"] || &1["role"])) == ["user", "assistant", "call_a", "call_b", "call_c", "user"]
      assert %{"is_error" => true, "details" => %{"repaired" => true}} = Enum.at(messages, 4)

      for body <- [Anthropic.build_body(%{model: "m", messages: messages}), OpenAI.build_body(%{model: "m", messages: messages})] do
        assert is_list(body["messages"])
      end
    end
  end

  describe "Task 52: steer and cancel during backoff settle the durable task" do
    defp rate_limited_once(counter) do
      fn _p, _c ->
        :counters.add(counter, 1, 1)
        if :counters.get(counter, 1) == 1, do: {:retry_after, 60_000}, else: {:ok, Faults.text_msg("answer")}
      end
    end

    defp restart_and_count(conv_id, pid, counter) do
      GenServer.stop(pid)
      calls = :counters.get(counter, 1)

      # Whatever the wake job does, nothing is left to resume.
      Repo.all(from t in TaskSchema, where: t.conversation_id == ^conv_id)
      |> Enum.each(&SuperPi.Workers.GenerationWakeWorker.perform(%Oban.Job{args: %{"task_id" => &1.id}}))

      {:ok, pid2} = Machine.start_link(conversation_id: conv_id, llm_responder: rate_limited_once(counter))
      eventually(fn -> machine_state(pid2) == :idle end)
      GenServer.stop(pid2)
      :counters.get(counter, 1) - calls
    end

    test "steer: the turn completes, the task is completed and is not replayed after a restart" do
      conv = Storage.create_conversation!()
      counter = :counters.new(1, [])
      {:ok, pid} = Machine.start_link(conversation_id: conv.id, llm_responder: rate_limited_once(counter))

      turn = Task.async(fn -> submit(pid, "hi") end)
      eventually(fn -> machine_state(pid) == :sleeping_backoff end)
      assert {:ok, :steered} = submit(pid, "STEER", mode: :steer)
      assert {:ok, _} = Task.await(turn, 5_000)

      assert [%{status: "completed"}] = generation_tasks(conv.id)
      assert restart_and_count(conv.id, pid, counter) == 0
    end

    test "cancel: the task is cancelled and is not replayed after a restart" do
      conv = Storage.create_conversation!()
      counter = :counters.new(1, [])
      {:ok, pid} = Machine.start_link(conversation_id: conv.id, llm_responder: rate_limited_once(counter))

      turn = Task.async(fn -> submit(pid, "hi") end)
      eventually(fn -> machine_state(pid) == :sleeping_backoff end)
      Machine.cancel(pid)
      assert {:error, :cancelled} = Task.await(turn, 5_000)

      assert [%{status: "cancelled"}] = generation_tasks(conv.id)
      assert restart_and_count(conv.id, pid, counter) == 0
    end

    test "a sleeping task can be failed" do
      conv = Storage.create_conversation!()
      {:ok, task} = TaskEngine.create_task(conv.id, "pi.generation")
      {:ok, _} = TaskEngine.start_task(task.id)
      {:ok, _} = TaskEngine.sleep_until(task.id, DateTime.add(DateTime.utc_now(), 60, :second))
      assert {:ok, %{status: "failed"}} = TaskEngine.fail_task(task.id, "boom")
    end
  end

  describe "Task 54: drain, cancel and steer during a running tool" do
    test "the machine answers get_state while a tool runs, so drain sees the turn as busy" do
      conv = Storage.create_conversation!()
      test_pid = self()

      executor = fn _n, _a, _c ->
        send(test_pid, :tool_started)
        Process.sleep(1_500)
        %{"output" => "slow"}
      end

      {:ok, pid} =
        Machine.start_link(conversation_id: conv.id, llm_responder: Faults.tool_then_text_responder("t", %{}, "done"), tool_executor: executor)

      turn = Task.async(fn -> submit(pid, "go") end)
      assert_receive :tool_started, 5_000

      assert conv.id in SuperPi.Drain.busy_conversations()
      assert {:ok, _} = Task.await(turn, 10_000)
    end

    @tag :tmp_dir
    test "cancel stops a running shell command and its child processes within a second", %{tmp_dir: dir} do
      conv = Storage.create_conversation!()
      pid_file = Path.join(dir, "child.pid")
      test_pid = self()

      executor = fn _n, _a, _c ->
        send(test_pid, :tool_started)
        SuperPi.Env.SandboxRunner.exec_command("sh", ["-c", "sleep 30 & echo $! > #{pid_file}; wait"])
        %{"output" => "finished"}
      end

      {:ok, pid} =
        Machine.start_link(conversation_id: conv.id, llm_responder: Faults.tool_then_text_responder("t", %{}, "done"), tool_executor: executor)

      turn = Task.async(fn -> submit(pid, "go") end)
      assert_receive :tool_started, 5_000
      eventually(fn -> File.exists?(pid_file) and File.read!(pid_file) != "" end)
      child = pid_file |> File.read!() |> String.trim()

      {micros, _} =
        :timer.tc(fn ->
          Machine.cancel(pid)
          assert {:error, :cancelled} = Task.await(turn, 5_000)
          eventually(fn -> match?({_, 1}, System.cmd("kill", ["-0", child], stderr_to_stdout: true)) end, 100)
        end)

      assert micros < 1_000_000 + 100_000
      assert_tool_pairs(Context.derive(conv.id).messages)
    end
  end

  describe "Task 57: the after_response hook result is stored and dispatched" do
    defmodule DropSecondCall do
      use SuperPi.Extension

      @impl true
      def after_response(msg, _ctx) do
        {:ok, Map.update!(msg, "content", fn content -> Enum.reject(content, &(&1["id"] == "call_b")) end)}
      end
    end

    test "a tool call removed by the hook is neither stored nor run" do
      conv = Storage.create_conversation!()
      test_pid = self()

      responder = fn payload, _ctx ->
        if Enum.any?(payload.messages, &(&1["role"] == "tool")), do: {:ok, Faults.text_msg("done")}, else: {:ok, two_tool_calls()}
      end

      executor = fn _name, %{"n" => n}, _ctx ->
        send(test_pid, {:ran, n})
        %{"output" => n}
      end

      {:ok, pid} =
        Machine.start_link(conversation_id: conv.id, llm_responder: responder, tool_executor: executor, extensions: [DropSecondCall])

      assert {:ok, _} = submit(pid, "go")
      assert_received {:ran, "a"}
      refute_received {:ran, "b"}

      messages = Context.derive(conv.id).messages
      refute Enum.any?(messages, &(&1["tool_call_id"] == "call_b"))
      [assistant | _] = for %{"role" => "assistant"} = m <- messages, do: m
      assert Enum.map(assistant["content"], & &1["id"]) == ["call_a"]
    end
  end

  describe "Task 53: the gateway stores OpenAI tool call arguments as a map" do
    import Plug.Conn
    import Plug.Test

    defp chat(messages) do
      body = %{"model" => "super-pi-agent", "stream" => false, "messages" => messages}

      conn(:post, "/v1/chat/completions", Jason.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> SuperPi.Gateway.Router.call(SuperPi.Gateway.Router.init([]))
    end

    defp history(arguments) do
      [
        %{"role" => "user", "content" => "read mix.exs"},
        %{
          "role" => "assistant",
          "content" => nil,
          "tool_calls" => [%{"id" => "call_1", "type" => "function", "function" => %{"name" => "read", "arguments" => arguments}}]
        },
        %{"role" => "tool", "tool_call_id" => "call_1", "content" => "defmodule X"},
        %{"role" => "user", "content" => "thanks"}
      ]
    end

    test "seeded arguments are decoded, so both providers get one JSON object" do
      SuperPi.Tools.ensure_catalog_ets!()
      conn = chat(history(~s({"path":"mix.exs"})))
      assert conn.status == 200

      conv_id = Repo.one(from c in SuperPi.Durable.Schemas.Conversation, select: max(c.id))
      messages = Context.derive(conv_id).messages

      assert [%{"type" => "tool_call", "arguments" => %{"path" => "mix.exs"}}] =
               Enum.find_value(messages, &(&1["role"] == "assistant" && &1["content"]))

      anthropic = Anthropic.build_body(%{model: "m", messages: messages})["messages"]
      assert %{"type" => "tool_use", "input" => %{"path" => "mix.exs"}} = anthropic |> Enum.at(1) |> Map.get("content") |> List.last()

      openai = OpenAI.build_body(%{model: "m", messages: messages})["messages"]
      [%{"function" => %{"arguments" => encoded}}] = Enum.find_value(openai, & &1["tool_calls"])
      assert Jason.decode!(encoded) == %{"path" => "mix.exs"}
    end

    test "arguments that are not a JSON object are refused with 400 naming the tool call" do
      conn = chat(history(~s({"path":)))
      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["code"] == "invalid_tool_call_arguments"
      assert body["error"]["message"] =~ "call_1"
    end
  end

  describe "Task 55: session.compact runs through the machine" do
    defp rpc_compact(conv_id) do
      payload = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "session.compact", "params" => %{"conversation_id" => conv_id}})
      {reply, _state, _notifs} = SuperPi.RPC.Server.handle_rpc_payload(payload, SuperPi.RPC.Server.new_client_state())
      reply
    end

    test "nothing to compact is a result, not an internal error" do
      conv = Storage.create_conversation!()
      Storage.append_entry!(conv.id, "pi.message", %{"role" => "user", "content" => [%{"type" => "text", "text" => "hi"}]})

      assert %{"result" => %{"compacted" => false, "reason" => "noop"}} = rpc_compact(conv.id)
    end

    test "a compact request during a turn waits for the turn to end" do
      conv = Storage.create_conversation!()
      test_pid = self()

      for i <- 1..6 do
        Storage.append_entry!(conv.id, "pi.message", %{"role" => "user", "content" => [%{"type" => "text", "text" => String.duplicate("old #{i} ", 2_000)}]})
        Storage.append_entry!(conv.id, "pi.message", %{"role" => "assistant", "content" => [%{"type" => "text", "text" => String.duplicate("reply ", 2_000)}]})
      end

      responder = fn _p, _c ->
        send(test_pid, {:streaming, self()})
        receive(do: (:release -> {:ok, Faults.text_msg("done")}))
      end

      {:ok, pid} = SuperPi.Conversation.Locator.ensure_started(conv.id, llm_responder: responder)
      turn = Task.async(fn -> submit(pid, "go") end)
      assert_receive {:streaming, llm}, 5_000

      compact = Task.async(fn -> rpc_compact(conv.id) end)
      refute Task.yield(compact, 300), "compaction ran during the turn"

      send(llm, :release)
      assert {:ok, _} = Task.await(turn, 5_000)
      assert %{"result" => %{"compacted" => true, "entry_id" => entry_id}} = Task.await(compact, 10_000)

      last_message = Repo.one(from e in SuperPi.Durable.Schemas.Entry, where: e.conversation_id == ^conv.id and e.kind == "pi.message", select: max(e.id))
      assert entry_id > last_message
    end
  end
end
