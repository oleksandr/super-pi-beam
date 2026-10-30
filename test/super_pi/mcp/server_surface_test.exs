defmodule SuperPi.MCP.ServerSurfaceTest do
  @moduledoc "Server surface: annotations, structuredContent, harness prompts, harness selection, transcripts (C3)."
  use SuperPi.DataCase, async: false

  alias SuperPi.Harness
  alias SuperPi.MCP.Server

  setup do
    SuperPi.Tools.ensure_catalog_ets!()

    saved = for key <- [:permissions, :workspace_paths, :mcp_harness], do: {key, Application.fetch_env(:super_pi, key)}
    Application.put_env(:super_pi, :permissions, allowNonWorkspaceAccess: true)

    on_exit(fn ->
      for {key, saved} <- saved do
        case saved do
          {:ok, v} -> Application.put_env(:super_pi, key, v)
          :error -> Application.delete_env(:super_pi, key)
        end
      end
    end)

    :ok
  end

  defp rpc(state, method, params \\ %{}) do
    request = %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}
    {:reply, reply, state} = Server.handle_mcp_line(Jason.encode!(request), state)
    {reply, state}
  end

  defp harness_task(state, args), do: rpc(state, "tools/call", %{"name" => "harness_task", "arguments" => args})

  describe "tool annotations" do
    test "each of the eight tools states all four hints" do
      {reply, _} = rpc(%{}, "tools/list")
      tools = reply["result"]["tools"]

      assert tools |> Enum.map(& &1["name"]) |> Enum.sort() == ~w(bash edit find grep harness_task ls read write)

      for tool <- tools do
        assert %{"readOnlyHint" => _, "destructiveHint" => _, "idempotentHint" => _, "openWorldHint" => _} = tool["annotations"]
        assert tool["annotations"] |> Map.values() |> Enum.all?(&is_boolean/1)
      end
    end

    test "read-only tools are read-only, writers are destructive, the shell is open-world" do
      {reply, _} = rpc(%{}, "tools/list")
      by_name = Map.new(reply["result"]["tools"], &{&1["name"], &1["annotations"]})

      for name <- ~w(read grep find ls) do
        assert %{"readOnlyHint" => true, "destructiveHint" => false, "idempotentHint" => true} = by_name[name]
      end

      for name <- ~w(write edit bash harness_task) do
        assert %{"readOnlyHint" => false, "destructiveHint" => true} = by_name[name]
      end

      assert by_name["bash"]["openWorldHint"]
      assert by_name["write"]["idempotentHint"]
      refute by_name["edit"]["idempotentHint"]
      refute by_name["read"]["openWorldHint"]
    end

    test "harness_task takes a harness argument that lists the harness ids" do
      {reply, _} = rpc(%{}, "tools/list")
      tool = Enum.find(reply["result"]["tools"], &(&1["name"] == "harness_task"))

      assert tool["inputSchema"]["properties"]["harness"]["enum"] == Enum.map(Harness.list(), & &1.id())
      assert tool["inputSchema"]["required"] == ["prompt"]
    end
  end

  describe "structuredContent" do
    test "harness_task returns its harness and conversation id" do
      {reply, _} = harness_task(%{}, %{"prompt" => "hello"})

      assert %{"isError" => false, "structuredContent" => %{"harness" => harness, "conversation_id" => conv_id}} = reply["result"]
      assert harness == Harness.default().id()
      assert is_integer(conv_id)
      assert {:ok, _} = Jason.encode(reply)
    end

    test "a built-in tool passes its structured output through" do
      {reply, _} = rpc(%{}, "tools/call", %{"name" => "ls", "arguments" => %{"path" => System.tmp_dir!()}})
      assert reply["result"]["isError"] == false
      assert %{} = structured = reply["result"]["structuredContent"]
      assert map_size(structured) > 0
    end

    test "an error result keeps isError and a structured payload that JSON can carry" do
      {reply, _} = harness_task(%{}, %{"prompt" => "x", "harness" => "nope"})
      assert reply["result"]["isError"] == true
      assert {:ok, _} = Jason.encode(reply)
    end
  end

  describe "harnesses as prompts" do
    test "prompts/list has one prompt per harness, then the plan_architecture alias" do
      {reply, _} = rpc(%{}, "prompts/list")
      prompts = reply["result"]["prompts"]

      assert Enum.map(prompts, & &1["name"]) == Enum.map(Harness.list(), & &1.id()) ++ ["plan_architecture"]
      assert Enum.all?(prompts, fn p -> [%{"name" => "goal", "required" => true}] = p["arguments"] end)
      assert Enum.all?(prompts, &is_binary(&1["description"]))
    end

    test "prompts/get for a harness points the host at harness_task with that harness" do
      [harness | _] = Harness.list()
      {reply, _} = rpc(%{}, "prompts/get", %{"name" => harness.id(), "arguments" => %{"goal" => "map the repo"}})

      assert [%{"role" => "user", "content" => %{"type" => "text", "text" => text}}] = reply["result"]["messages"]
      assert text =~ "harness_task"
      assert text =~ harness.id()
      assert text =~ "map the repo"
    end

    test "prompts/get without a goal, or for an unknown prompt, is -32602" do
      [harness | _] = Harness.list()
      {missing, _} = rpc(%{}, "prompts/get", %{"name" => harness.id(), "arguments" => %{}})
      assert missing["error"]["code"] == -32602
      assert missing["error"]["message"] =~ "goal"

      {unknown, _} = rpc(%{}, "prompts/get", %{"name" => "nope", "arguments" => %{"goal" => "x"}})
      assert unknown["error"]["code"] == -32602
    end

    test "plan_architecture still answers as it did" do
      {reply, _} = rpc(%{}, "prompts/get", %{"name" => "plan_architecture", "arguments" => %{"goal" => "ship"}})
      assert [%{"content" => %{"text" => "Please create an architectural plan for: ship"}}] = reply["result"]["messages"]
    end
  end

  describe "harness selection (D7)" do
    test "harness_task runs in the harness it is asked for" do
      for harness <- Harness.list() |> Enum.take(2) do
        {reply, _} = harness_task(%{}, %{"prompt" => "hi", "harness" => harness.id()})
        assert reply["result"]["structuredContent"]["harness"] == harness.id()
      end
    end

    test "an unknown harness is an error that lists the choices, and nothing runs" do
      {reply, state} = harness_task(%{}, %{"prompt" => "hi", "harness" => "does-not-exist"})
      assert reply["result"]["isError"] == true
      assert [%{"text" => text}] = reply["result"]["content"]
      assert text =~ "Unknown harness"
      assert text =~ Harness.default().id()
      refute Map.has_key?(state, :conversations)
    end

    test "a harness that is not a string is an error" do
      {reply, _} = harness_task(%{}, %{"prompt" => "hi", "harness" => 7})
      assert reply["result"]["isError"] == true
    end

    test "without an argument the connection's harness runs: state, then config, then the default" do
      [first, second | _] = Harness.list()

      {reply, _} = harness_task(%{harness: second.id()}, %{"prompt" => "hi"})
      assert reply["result"]["structuredContent"]["harness"] == second.id()

      Application.put_env(:super_pi, :mcp_harness, first.id())
      {reply, _} = harness_task(%{}, %{"prompt" => "hi"})
      assert reply["result"]["structuredContent"]["harness"] == first.id()

      # The state wins over the config.
      {reply, _} = harness_task(%{harness: second.id()}, %{"prompt" => "hi"})
      assert reply["result"]["structuredContent"]["harness"] == second.id()
    end

    test "direct tool calls use the connection's harness for their permission session" do
      [_, second | _] = Harness.list()
      {_reply, state} = rpc(%{harness: second.id()}, "tools/call", %{"name" => "ls", "arguments" => %{"path" => System.tmp_dir!()}})

      agent = SuperPi.Durable.Doc.snapshot("conversation", state.tool_session.conversation_id, "pi.agent")
      assert agent["maxExecutionMode"] == second.agent_defaults()["maxExecutionMode"]
    end
  end

  describe "workspace" do
    @describetag :tmp_dir

    test "working_directory and the tool session's workspace_root come from the configured workspace paths", %{tmp_dir: dir} do
      Application.put_env(:super_pi, :workspace_paths, [dir])

      {reply, _} = rpc(%{}, "resources/read", %{"uri" => "superpi://workspace/context"})
      context = reply["result"]["contents"] |> hd() |> Map.fetch!("text") |> Jason.decode!()
      assert context["working_directory"] == Path.expand(dir)
      assert context["workspace_paths"] == [Path.expand(dir)]
      assert context["harness"] == Harness.default().id()

      {_reply, state} = rpc(%{}, "tools/call", %{"name" => "ls", "arguments" => %{"path" => dir}})
      assert state.tool_session.workspace_root == Path.expand(dir)
    end
  end

  describe "conversation transcripts" do
    test "resources/templates/list names the transcript template" do
      {reply, _} = rpc(%{}, "resources/templates/list")

      assert [%{"uriTemplate" => "superpi://conversation/{id}/transcript", "name" => _, "mimeType" => _}] =
               reply["result"]["resourceTemplates"]
    end

    test "a harness_task conversation is listed and its transcript is read as JSON lines" do
      {task, state} = harness_task(%{}, %{"prompt" => "remember this"})
      conv_id = task["result"]["structuredContent"]["conversation_id"]
      uri = "superpi://conversation/#{conv_id}/transcript"

      {list, _} = rpc(state, "resources/list")
      assert uri in Enum.map(list["result"]["resources"], & &1["uri"])

      {read, _} = rpc(state, "resources/read", %{"uri" => uri})
      assert [%{"uri" => ^uri, "mimeType" => "application/x-ndjson", "text" => text}] = read["result"]["contents"]

      steps = text |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
      assert steps != []
      assert Enum.map(steps, & &1["step_index"]) == Enum.to_list(1..length(steps))
      assert Enum.any?(steps, &(&1["content"] =~ "remember this"))
    end

    test "another principal does not find the conversation" do
      {task, state} = harness_task(%{principal: "token:alice"}, %{"prompt" => "secret plans"})
      uri = "superpi://conversation/#{task["result"]["structuredContent"]["conversation_id"]}/transcript"

      assert {%{"result" => %{"contents" => [_]}}, _} = rpc(state, "resources/read", %{"uri" => uri})

      {other, _} = rpc(%{principal: "token:bob"}, "resources/read", %{"uri" => uri})
      assert other["error"]["code"] == -32002

      {anonymous, _} = rpc(%{}, "resources/read", %{"uri" => uri})
      assert anonymous["error"]["code"] == -32002
    end

    test "an unknown, malformed or foreign-shaped URI is -32002" do
      for uri <- [
            "superpi://conversation/999999999/transcript",
            "superpi://conversation/abc/transcript",
            "superpi://conversation/1x/transcript",
            "superpi://conversation/0/transcript",
            "superpi://conversation/1/other",
            "superpi://conversation/1/transcript/extra",
            "superpi://conversation/"
          ] do
        {reply, _} = rpc(%{}, "resources/read", %{"uri" => uri})
        assert reply["error"]["code"] == -32002, "#{uri}: #{inspect(reply)}"
      end
    end
  end
end
