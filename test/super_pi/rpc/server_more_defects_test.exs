defmodule SuperPi.RPC.ServerMoreDefectsTest do
  @moduledoc """
  Regression tests that reproduce further RPC defects found in the code review
  (rpc/server.ex). Every test is expected to FAIL on the current code and pass
  once the matching finding is fixed.

  Run only these:  mix test --only known_bug
  Skip these:      mix test --exclude known_bug
  """
  use SuperPi.DataCase, async: false

  alias SuperPi.Conversation.Machine
  alias SuperPi.Durable.{Doc, Storage}
  alias SuperPi.RPC.Server
  alias SuperPi.TestSupport.Faults


  defp request(id, method, params) do
    Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})
  end

  defp handle(method, params, state \\ Server.new_client_state()) do
    Server.handle_rpc_payload(request(1, method, params), state)
  end

  defp connect do
    {:ok, server} = Server.start_link(port: 0)
    {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", Server.port(server), [:binary, packet: :raw, active: false])
    on_exit(fn -> :gen_tcp.close(sock) end)
    sock
  end

  # Reads up to the next newline. Returns {:ok, decoded} | {:error, reason}.
  defp recv_json(sock, timeout, buf \\ "") do
    case String.split(buf, "\n", parts: 2) do
      [line, _rest] ->
        {:ok, Jason.decode!(line)}

      [_] ->
        case :gen_tcp.recv(sock, 0, timeout) do
          {:ok, data} -> recv_json(sock, timeout, buf <> data)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # A process registered as the conversation's machine that never replies
  # (:hang) or dies when it receives the first call (:die).
  defp start_fake_machine(conv_id, behavior) do
    test = self()

    pid =
      spawn(fn ->
        {:ok, _} = Horde.Registry.register(SuperPi.Conversation.Locator.registry(), {:conversation_machine, conv_id}, nil)
        send(test, :fake_registered)

        receive do
          {:"$gen_call", _from, _req} ->
            case behavior do
              :die -> exit(:boom)
              :hang -> Process.sleep(:infinity)
            end
        end
      end)

    assert_receive :fake_registered, 1_000
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  describe "packet: :line truncates long requests (rpc/server.ex:152)" do
    test "a ~100KB request over TCP gets a normal reply, not -32700" do
      sock = connect()
      padding = String.duplicate("a", 100_000)

      :ok = :gen_tcp.send(sock, request(1, "session.open", %{"pad" => padding}) <> "\n")

      assert {:ok, reply} = recv_json(sock, 3_000)
      assert reply["error"] == nil, "long line was rejected: #{inspect(reply["error"])}"
      assert is_integer(reply["result"]["conversation_id"])
    end
  end

  describe "machine lifecycle (rpc/server.ex:478-486, 281)" do
    test "the conversation machine survives the death of the connection process that started it" do
      conv = Storage.create_conversation!()

      {pid, ref} =
        spawn_monitor(fn ->
          {_reply, _, _} = handle("session.open", %{"conversation_id" => conv.id})
          exit(:connection_crashed)
        end)

      assert_receive {:DOWN, ^ref, :process, ^pid, :connection_crashed}, 5_000

      assert [{machine, _}] = Horde.Registry.lookup(SuperPi.Conversation.Locator.registry(), {:conversation_machine, conv.id}),
             "machine is gone after its connection process exited"

      assert Process.alive?(machine)
    end
  end

  describe "synchronous session.submit (rpc/server.ex:285,317)" do
    test "a slow submit does not block other requests on the same connection" do
      conv_id = 424_242
      start_fake_machine(conv_id, :hang)
      sock = connect()

      :ok = :gen_tcp.send(sock, request(1, "session.submit", %{"conversation_id" => conv_id, "text" => "hi"}) <> "\n")
      :ok = :gen_tcp.send(sock, request(2, "session.cancel", %{"conversation_id" => conv_id}) <> "\n")

      assert {:ok, %{"id" => 2}} = recv_json(sock, 1_000),
             "session.cancel was not answered within 1s while a submit was pending"
    end

    test "a machine that dies mid-submit yields a JSON-RPC error instead of closing the connection" do
      conv_id = 424_243
      start_fake_machine(conv_id, :die)
      sock = connect()

      :ok = :gen_tcp.send(sock, request(1, "session.submit", %{"conversation_id" => conv_id, "text" => "hi"}) <> "\n")

      assert {:ok, reply} = recv_json(sock, 2_000)
      assert is_map(reply["error"])
    end

    test "an async submit whose machine dies broadcasts turn_error" do
      conv_id = 424_244
      start_fake_machine(conv_id, :die)
      Phoenix.PubSub.subscribe(SuperPi.PubSub, "conversation:#{conv_id}")

      {reply, _, _} =
        handle("session.submit", %{"conversation_id" => conv_id, "text" => "hi", "async" => true})

      assert reply["result"]["status"] == "accepted"

      assert_receive {:conversation_event, ^conv_id, %{"type" => "turn_error"}}, 1_000
    end
  end

  describe "session.cancel (rpc/server.ex:423-438)" do
    test "stops the running turn instead of only broadcasting turn_cancelled" do
      Process.flag(:trap_exit, true)
      conv = Storage.create_conversation!()

      {:ok, machine} =
        Machine.start_link(
          conversation_id: conv.id,
          llm_responder: Faults.blocking_responder(self(), "finished")
        )

      Phoenix.PubSub.subscribe(SuperPi.PubSub, "conversation:#{conv.id}")

      {_reply, _, _} =
        handle("session.submit", %{"conversation_id" => conv.id, "text" => "long task", "async" => true})

      assert_receive {:responder_started, responder}, 5_000
      on_exit(fn -> if Process.alive?(responder), do: send(responder, :release) end)

      {_reply, _, _} = handle("session.cancel", %{"conversation_id" => conv.id})
      assert_receive {:conversation_event, _, %{"type" => "turn_cancelled"}}, 1_000

      # The machine is idle again: the turn did not keep running.
      assert_receive {:conversation_event, _, %{"type" => "state_changed", "status" => "idle"}},
                     1_000,
                     "the turn kept running after session.cancel"

      assert Process.alive?(machine)
    end
  end

  describe "session.open on an existing conversation (rpc/server.ex:243-258)" do
    test "keeps the conversation's configured agent when the request carries no agent" do
      conv = Storage.create_conversation!(agent: %{"model" => "custom-model-xyz"})

      {reply, _, _} = handle("session.open", %{"conversation_id" => conv.id})

      assert reply["result"]["agent"]["model"] == "custom-model-xyz"
      assert Doc.snapshot("conversation", conv.id, "pi.agent")["model"] == "custom-model-xyz"
    end
  end

  describe "coalesced queue (rpc/server.ex:77-101)" do
    test "is capped for a client that never acks" do
      state = Server.new_client_state()

      final =
        Enum.reduce(1..10_000, state, fn i, acc ->
          {next, _notifs} = Server.enqueue_watch_event(acc, %{"type" => "delta", "n" => i})
          next
        end)

      assert length(final.coalesced_queue) <= 1_000, "queue grew to #{length(final.coalesced_queue)} entries"
    end
  end
end
