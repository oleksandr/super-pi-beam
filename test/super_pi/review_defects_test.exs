defmodule SuperPi.ReviewDefectsTest do
  @moduledoc """
  Regression tests for the review findings of Task 45 (note 26). Each test failed on the
  code before its fix.
  """
  use SuperPi.DataCase, async: false

  import Ecto.Query
  require Record

  Record.defrecord(:span, Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl"))

  alias SuperPi.Auth
  alias SuperPi.Durable.{Doc, Storage, TaskEngine}
  alias SuperPi.Durable.Schemas.Task, as: TaskSchema
  alias SuperPi.MCP.Manager
  alias SuperPi.Plugins.{Handoff, Subagent}
  alias SuperPi.RPC.Server, as: RPC
  alias SuperPi.TestSupport.Faults

  @script Path.expand("../support/fake_mcp_server.exs", __DIR__)

  defp put_env(key, value) do
    old = Application.fetch_env(:super_pi, key)
    Application.put_env(:super_pi, key, value)

    on_exit(fn ->
      case old do
        {:ok, v} -> Application.put_env(:super_pi, key, v)
        :error -> Application.delete_env(:super_pi, key)
      end
    end)
  end

  describe "handoff child (high 1)" do
    test "inherits the parent's mode, workspace and settings, and the parent's owner" do
      settings = %{"permissions" => %{"deny" => ["command(curl)"]}}

      parent =
        Storage.create_conversation!(
          agent: %{"model" => "m", "executionMode" => "plan", "workspacePaths" => ["/srv/ws"], "settingsOverride" => settings}
        )

      Auth.claim!(parent.id, "alice")

      res = Handoff.wrap_tool("handoff", %{"goal" => "g", "summary" => "s"}, fn _ -> %{} end, %{conversation_id: parent.id})
      child_id = res["structured_output"]["child_conversation_id"]
      agent = Doc.snapshot("conversation", child_id, "pi.agent")

      assert agent["executionMode"] == "plan"
      assert agent["workspacePaths"] == ["/srv/ws"]
      assert agent["settingsOverride"] == settings
      assert agent["dangerouslySkipPermissions"] == false
      assert Auth.owner(child_id) == "alice"
    end

    test "a parent without a mode gives a child in accept-edits, never auto" do
      parent = Storage.create_conversation!(agent: %{})
      res = Handoff.wrap_tool("handoff", %{"goal" => "g", "summary" => "s"}, fn _ -> %{} end, %{conversation_id: parent.id})
      agent = Doc.snapshot("conversation", res["structured_output"]["child_conversation_id"], "pi.agent")
      assert agent["executionMode"] == "accept-edits"
    end
  end

  describe "InlineBash for remote callers (high 2)" do
    defp module_of(ext), do: if(is_tuple(ext), do: elem(ext, 0), else: ext)

    test "remote_extensions drops InlineBash, and the harness itself has it" do
      assert SuperPi.Plugins.InlineBash in Enum.map(SuperPi.Harness.Interactive.extensions([]), &module_of/1)
      refute SuperPi.Plugins.InlineBash in Enum.map(SuperPi.Harness.remote_extensions(SuperPi.Harness.Interactive), &module_of/1)
    end

    test "an RPC session on the interactive harness runs without InlineBash" do
      payload = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "session.open", "params" => %{"harness" => "super-pi-interactive"}})
      {%{"result" => %{"conversation_id" => conv_id}}, _, _} = RPC.handle_rpc_payload(payload, RPC.new_client_state())

      [{pid, _}] = Horde.Registry.lookup(SuperPi.Conversation.Locator.registry(), {:conversation_machine, conv_id})
      {_state, data} = :gen_statem.call(pid, :get_state)
      refute SuperPi.Plugins.InlineBash in Enum.map(data.extensions, &module_of/1)
      on_exit(fn -> Process.exit(pid, :kill) end)
    end
  end

  describe "MCP harness_task (high 3)" do
    test "a turn that exceeds the timeout returns an error and the server keeps running" do
      put_env(:mcp_harness_task_timeout_ms, 300)
      put_env(:mcp_harness_task_opts, llm_responder: fn _p, _c -> Process.sleep(3_000) && {:ok, Faults.text_msg("late")} end)
      SuperPi.Tools.ensure_catalog_ets!()

      req = %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/call", "params" => %{"name" => "harness_task", "arguments" => %{"prompt" => "slow"}}}
      assert {:reply, %{"result" => result}, _state} = SuperPi.MCP.Server.handle_mcp_line(Jason.encode!(req), %{})

      assert result["isError"] == true
      assert [%{"text" => text}] = result["content"]
      assert text =~ "timed out"
    end

    test "a machine that crashes does not crash the caller" do
      put_env(:mcp_harness_task_opts, llm_responder: fn _p, _c -> exit(:boom) end)
      SuperPi.Tools.ensure_catalog_ets!()

      req = %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/call", "params" => %{"name" => "harness_task", "arguments" => %{"prompt" => "x"}}}
      assert {:reply, %{"result" => %{"isError" => true}}, _} = SuperPi.MCP.Server.handle_mcp_line(Jason.encode!(req), %{})
    end
  end

  describe "MCP launch failure (high 4)" do
    setup do
      Manager.create_tables()
      Manager.stop_all()
      on_exit(&Manager.stop_all/0)
      dir = Path.join(System.tmp_dir!(), "rd_mcp_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      %{dir: dir}
    end

    test "a server that never answers is stopped, with its OS process", %{dir: dir} do
      marker = "marker-#{System.unique_integer([:positive])}"
      put_env(:mcp_startup_timeout_ms, 600)

      File.write!(
        Path.join(dir, "mcp_config.json"),
        Jason.encode!(%{"mcpServers" => %{"stuck" => %{"command" => "elixir", "args" => [@script, marker], "env" => %{"FAKE_MCP_MODE" => "hang"}}}})
      )

      assert [%{status: {:error, :timeout}}] = Manager.ensure_started(global_config_dir: dir)
      assert DynamicSupervisor.which_children(SuperPi.MCPClientSupervisor) == []

      survivors =
        Enum.reduce_while(1..20, nil, fn _, _ ->
          case System.cmd("pgrep", ["-f", marker]) do
            {_, 0} -> Process.sleep(100) && {:cont, :alive}
            _ -> {:halt, :gone}
          end
        end)

      assert survivors == :gone, "the stuck server's OS process is still running"
    end

    test "two callers launch one server", %{dir: dir} do
      File.write!(Path.join(dir, "mcp_config.json"), Jason.encode!(%{"mcpServers" => %{"fake" => %{"command" => "elixir", "args" => [@script]}}}))

      results = 1..4 |> Task.async_stream(fn _ -> Manager.ensure_started(global_config_dir: dir) end, timeout: 30_000) |> Enum.flat_map(fn {:ok, r} -> r end)

      assert Enum.count(results, &(&1.status == :started)) == 1
      assert length(DynamicSupervisor.which_children(SuperPi.MCPClientSupervisor)) == 1
    end
  end

  describe "killed subagent (high 5)" do
    test "a child stuck outside its deadline is failed, and the parent turn is not left waiting" do
      put_env(:subagent_kill_slack_ms, 100)
      dir = Path.join(System.tmp_dir!(), "rd_sub_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      put_env(:mcp_startup_timeout_ms, 4_000)
      put_env(:mcp_clients, true)
      on_exit(&Manager.stop_all/0)

      File.write!(
        Path.join(dir, "mcp_config.json"),
        Jason.encode!(%{"mcpServers" => %{"stuck" => %{"command" => "elixir", "args" => [@script], "env" => %{"FAKE_MCP_MODE" => "hang"}}}})
      )

      parent = Storage.create_conversation!(agent: %{"model" => "m", "executionMode" => "accept-edits", "globalConfigDir" => dir})
      {:ok, task} = TaskEngine.create_task(parent.id, "pi.generation")
      {:ok, running} = TaskEngine.start_task(task.id)

      res =
        Subagent.wrap_tool(
          "delegate_subagent",
          %{"role" => "scout", "prompt" => "x", "timeout_ms" => 200},
          fn _ -> %{} end,
          %{conversation_id: parent.id, active_task_id: running.id}
        )

      assert [%{"status" => "failed"}] = res["structured_output"]["subagents"]
      assert [%{status: "failed"}] = Repo.all(from t in TaskSchema, where: t.kind == "pi.subagent")

      # The parent can now complete: no live child holds it in `completing`.
      assert {:ok, %{status: "completed"}} = TaskEngine.complete_task(running.id, %{})
    end
  end

  describe "subagent timeout cap (medium)" do
    test "the model cannot raise the timeout above the configured limit" do
      put_env(:subagent_timeout_ms, 300)
      parent = Storage.create_conversation!(agent: %{"model" => "m"})
      slow = fn _p, _c -> Process.sleep(3_000) && {:ok, Faults.text_msg("late")} end

      {micros, res} =
        :timer.tc(fn ->
          Subagent.wrap_tool("delegate_subagent", %{"role" => "scout", "prompt" => "x", "timeout_ms" => 1_000_000}, fn _ -> %{} end, %{
            conversation_id: parent.id,
            config: [machine_opts: [llm_responder: slow]]
          })
        end)

      assert [%{"status" => "failed", "error" => error}] = res["structured_output"]["subagents"]
      assert error =~ "timed out"
      assert div(micros, 1000) < 2_500
    end
  end

  describe "RPC robustness (medium)" do
    defp connect do
      path = Path.join("/tmp", "rd_#{System.unique_integer([:positive])}.sock")
      {:ok, server} = RPC.start_link(socket_path: path)
      {:ok, sock} = :gen_tcp.connect({:local, to_charlist(path)}, 0, [:binary, packet: :line, active: false])

      on_exit(fn ->
        :gen_tcp.close(sock)
        if Process.alive?(server), do: GenServer.stop(server)
        File.rm(path)
      end)

      sock
    end

    defp call(sock, id, method, params) do
      :ok = :gen_tcp.send(sock, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}) <> "\n")
      recv_reply(sock, id)
    end

    defp recv_reply(sock, id) do
      {:ok, line} = :gen_tcp.recv(sock, 0, 10_000)

      case Jason.decode!(line) do
        %{"id" => ^id} = reply -> reply
        _notification -> recv_reply(sock, id)
      end
    end

    test "forking at an entry of another conversation is an error reply, and the connection survives" do
      sock = connect()
      %{"result" => %{"conversation_id" => a}} = call(sock, 1, "session.open", %{})
      %{"result" => %{"conversation_id" => b}} = call(sock, 2, "session.open", %{})
      entry = Storage.append_entry!(b, "pi.message", %{"role" => "user", "content" => "x"})

      assert %{"error" => %{"code" => -32602}} = call(sock, 3, "session.fork", %{"conversation_id" => a, "at_entry_id" => entry.id})
      assert %{"error" => %{"code" => -32602}} = call(sock, 4, "session.fork", %{"conversation_id" => a, "at_entry_id" => 999_999})
      assert %{"result" => _} = call(sock, 5, "session.open", %{})
    end

    test "opening a conversation that does not exist is an error reply" do
      sock = connect()
      assert %{"error" => %{"code" => -32004}} = call(sock, 1, "session.open", %{"conversation_id" => 888_888})
      assert %{"result" => _} = call(sock, 2, "session.open", %{})
    end

    test "a turn on a watched conversation emits at most K=2 session.event frames before an ack" do
      sock = connect()
      %{"result" => %{"conversation_id" => conv}} = call(sock, 1, "session.open", %{})
      call(sock, 2, "session.watch", %{"conversation_id" => conv})

      for i <- 1..3, do: call(sock, 10 + i, "session.submit", %{"conversation_id" => conv, "text" => "hi #{i}"})

      frames =
        Stream.repeatedly(fn -> :gen_tcp.recv(sock, 0, 500) end)
        |> Enum.take_while(&match?({:ok, _}, &1))
        |> Enum.map(fn {:ok, l} -> Jason.decode!(l) end)

      events = Enum.filter(frames, &(&1["method"] == "session.event"))
      assert length(events) <= 2, "#{length(events)} session.event frames without an ack"
    end
  end

  describe "UI broker (medium)" do
    test "a question is cancelled when its last responder exits" do
      conv = Storage.create_conversation!()
      Phoenix.PubSub.subscribe(SuperPi.PubSub, "conversation:#{conv.id}")

      responder =
        spawn(fn ->
          SuperPi.UI.Broker.register_responder(conv.id)
          Process.sleep(:infinity)
        end)

      Process.sleep(50)
      task = Task.async(fn -> SuperPi.UI.Broker.ask(conv.id, %{"kind" => "questionnaire", "questions" => []}, 30_000) end)
      assert_receive {:conversation_event, _, %{"type" => "ui_request"}}, 5_000

      {micros, result} =
        :timer.tc(fn ->
          Process.exit(responder, :kill)
          Task.await(task, 5_000)
        end)

      assert result == {:error, :cancelled}
      assert div(micros, 1000) < 2_000
      refute SuperPi.UI.Broker.responder?(conv.id)
    end
  end

  describe "gateway sessions (medium)" do
    @opts SuperPi.Gateway.Router.init([])

    defp chat_session(sid) do
      body = %{"model" => "super-pi-workspace", "messages" => [%{"role" => "user", "content" => "hi"}]}

      Plug.Test.conn(:post, "/v1/chat/completions", Jason.encode!(body))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("x-session-id", sid)
      |> SuperPi.Gateway.Router.call(@opts)
    end

    test "the session table is bounded" do
      put_env(:gateway_session_limit, 3)

      for i <- 1..6, do: assert(chat_session("bounded-#{i}-#{System.unique_integer([:positive])}").status == 200)

      assert SuperPi.Gateway.Sessions.count() == 3
    end

    test "a session id keeps its conversation" do
      sid = "keep-#{System.unique_integer([:positive])}"
      chat_session(sid)
      first = SuperPi.Gateway.Sessions.lookup(SuperPi.Auth.anonymous(), sid)
      chat_session(sid)
      assert SuperPi.Gateway.Sessions.lookup(SuperPi.Auth.anonymous(), sid) == first
    end
  end

  describe "MCP startup (medium)" do
    test "a slow MCP server does not delay the machine start" do
      dir = Path.join(System.tmp_dir!(), "rd_slow_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      File.write!(
        Path.join(dir, "mcp_config.json"),
        Jason.encode!(%{"mcpServers" => %{"stuck" => %{"command" => "elixir", "args" => [@script], "env" => %{"FAKE_MCP_MODE" => "hang"}}}})
      )

      put_env(:mcp_clients, true)
      put_env(:mcp_startup_timeout_ms, 3_000)
      on_exit(&Manager.stop_all/0)

      conv = Storage.create_conversation!(agent: %{"globalConfigDir" => dir})

      {micros, {:ok, pid}} =
        :timer.tc(fn ->
          spec = %{id: {:rd, conv.id}, start: {SuperPi.Conversation.Machine, :start_link, [[conversation_id: conv.id, extensions: []]]}, restart: :temporary}
          Horde.DynamicSupervisor.start_child(SuperPi.MachineSupervisor, spec)
        end)

      # The server would hold the start for its 3 s timeout if the start waited for it.
      assert div(micros, 1000) < 2_000, "starting the machine took #{div(micros, 1000)} ms"
      on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    end
  end

  describe "create_task owner check (medium)" do
    test "a completed owner does not accept a child" do
      conv = Storage.create_conversation!()
      {:ok, owner} = TaskEngine.create_task(conv.id, "o")
      {:ok, _} = TaskEngine.start_task(owner.id)
      {:ok, _} = TaskEngine.complete_task(owner.id, %{})

      assert {:error, :invalid_owner_state} = TaskEngine.create_task(conv.id, "c", %{}, owner_task_id: owner.id)
    end
  end

  describe "low-severity findings" do
    test "the token name anonymous is reserved" do
      put_env(:gateway_tokens, anonymous: "tok")
      assert_raise ArgumentError, ~r/reserved/, fn -> Auth.tokens() end
    end

    test "a conversation is created owned, in one commit" do
      conv = Storage.create_conversation!(owner: "alice")
      assert Auth.owner(conv.id) == "alice"

      entry = Storage.append_entry!(conv.id, "pi.message", %{"role" => "user", "content" => "x"})
      fork = Storage.fork_conversation!(conv.id, entry.id, owner: "bob")
      assert Auth.owner(fork.id) == "bob"
    end

    test "metric labels are bounded" do
      SuperPi.Tools.ensure_catalog_ets!()
      before = SuperPi.Telemetry.scrape()

      SuperPi.Telemetry.tool_span("made-up-tool-#{System.unique_integer([:positive])}", fn -> %{"output" => "x"} end)
      SuperPi.Telemetry.tool_span("read", fn -> %{"output" => "x"} end)
      SuperPi.Telemetry.llm_span("invented-model-#{System.unique_integer([:positive])}", fn -> {:ok, %{"usage" => %{}}} end)

      text = SuperPi.Telemetry.scrape()
      assert text =~ ~s(tool="other")
      assert text =~ ~s(tool="read")
      assert text =~ ~s(model="other")
      refute text =~ "made-up-tool"
      refute text =~ "invented-model"
      assert is_binary(before)
    end

    test "a machine that stops mid-turn ends its turn span" do
      :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
      conv = Storage.create_conversation!()
      parent = self()

      responder = fn _p, _c ->
        send(parent, :in_turn)
        Process.sleep(5_000)
        {:ok, Faults.text_msg("late")}
      end

      {:ok, pid} = SuperPi.Conversation.Machine.start_link(conversation_id: conv.id, extensions: [], llm_responder: responder)
      Process.unlink(pid)
      Task.start(fn -> catch_exit(SuperPi.Conversation.Machine.submit(pid, "hi", timeout: 10_000)) end)
      assert_receive :in_turn, 5_000

      :gen_statem.stop(pid)
      assert_receive {:span, s}, 2_000
      assert span(s, :name) == "super_pi.turn"
      assert span(s, :status) != :undefined
    end

    test "a regular file at the socket path is not deleted" do
      path = Path.join(System.tmp_dir!(), "rd_notsock_#{System.unique_integer([:positive])}")
      File.write!(path, "precious")
      on_exit(fn -> File.rm(path) end)

      Process.flag(:trap_exit, true)
      assert {:error, _} = RPC.start_link(socket_path: path)
      assert File.read!(path) == "precious"
    end

    test "the socket is private to the owner and replaces an old socket" do
      path = Path.join("/tmp", "rd_#{System.unique_integer([:positive])}.sock")
      {:ok, first} = RPC.start_link(socket_path: path)
      Process.unlink(first)
      Process.exit(first, :kill)
      Process.sleep(50)

      {:ok, second} = RPC.start_link(socket_path: path)
      assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
      GenServer.stop(second)
      File.rm(path)
    end

    test "a plain user message that starts with 'generate a title' runs the agent" do
      body = %{"model" => "super-pi-workspace", "messages" => [%{"role" => "user", "content" => "Generate a title for my blog post"}]}

      conn =
        Plug.Test.conn(:post, "/v1/chat/completions", Jason.encode!(body))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("x-session-id", "title-#{System.unique_integer([:positive])}")
        |> SuperPi.Gateway.Router.call(SuperPi.Gateway.Router.init([]))

      assert conn.status == 200
      refute Jason.decode!(conn.resp_body)["id"] =~ "title"
    end
  end
end
