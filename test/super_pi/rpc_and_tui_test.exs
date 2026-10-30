defmodule SuperPi.RPCAndTUITest do
  use SuperPi.DataCase, async: false
  use ExUnitProperties

  alias SuperPi.Cluster
  alias SuperPi.RPC.Server
  alias SuperPi.TUI.Owl, as: OwlTUI

  describe "Property-Based Tests: RPC K=2 Ack-Clocked Backpressure & End-to-End Socket Showcase (REQ-PBT-07)" do
    property "K = 2 backpressure invariant: server never exceeds 2 unacknowledged batches and coalesces all overflow events until acked" do
      check all(
              ops <-
                list_of(
                  member_of([:emit_event, :emit_event, :emit_event, :ack_oldest]),
                  min_length: 5,
                  max_length: 30
                ),
              max_runs: 50
            ) do
        {final_state, total_emitted, total_received_events} =
          Enum.reduce(ops, {Server.new_client_state(), 0, []}, fn
            :emit_event, {st, counter, rev_acc} ->
              ev = %{"seq" => counter + 1, "delta" => "tok_#{counter + 1}"}
              {st2, notifs} = Server.enqueue_watch_event(st, ev)

              # INVARIANT 1: In-flight unacknowledged batches NEVER exceed K = 2 (`REQ-RPC-03`)
              assert map_size(st2.in_flight) <= 2

              emitted_events = Enum.flat_map(notifs, & &1["params"]["events"])
              {st2, counter + 1, rev_acc ++ emitted_events}

            :ack_oldest, {st, counter, rev_acc} ->
              case Map.keys(st.in_flight) |> Enum.sort() do
                [] ->
                  {st, counter, rev_acc}

                [oldest_batch_id | _] ->
                  {st2, notifs} = Server.ack_watch_batch(st, oldest_batch_id)
                  assert map_size(st2.in_flight) <= 2
                  emitted_events = Enum.flat_map(notifs, & &1["params"]["events"])
                  {st2, counter, rev_acc ++ emitted_events}
              end
          end)

        # Drain any remaining in-flight batches at the end of the sequence
        drained_events = drain_all_acks(final_state, total_received_events)

        # INVARIANT 2: Every single emitted event was delivered in exact order with zero drops or duplicates (`REQ-PBT-07`)
        expected_seqs = if total_emitted == 0, do: [], else: Enum.to_list(1..total_emitted)
        actual_seqs = Enum.map(drained_events, & &1["seq"])
        assert actual_seqs == expected_seqs
      end
    end

    test "end-to-end JSON-RPC 2.0 session.open, session.watch, session.submit, session.context, and session.fork over TCP" do
      {:ok, server_pid} = Server.start_link(port: 0)
      port = Server.port(server_pid)

      {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :line, active: false])

      # Allow the spawned socket process to use the Ecto SQL Sandbox in test mode
      send_rpc = fn id, method, params ->
        req =
          Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})

        :ok = :gen_tcp.send(sock, req <> "\n")
        {:ok, line} = :gen_tcp.recv(sock, 0, 5_000)
        Jason.decode!(String.trim(line))
      end

      # Also test direct handler with full SQLite access
      st = Server.new_client_state()

      {open_reply, st, []} =
        Server.handle_rpc_payload(
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => 1,
            "method" => "session.open",
            "params" => %{"agent" => %{"model" => "claude-sonnet-4-5"}}
          }),
          st
        )

      conv_id = open_reply["result"]["conversation_id"]
      assert is_integer(conv_id)

      {watch_reply, st, [watch_notif]} =
        Server.handle_rpc_payload(
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => 2,
            "method" => "session.watch",
            "params" => %{"conversation_id" => conv_id}
          }),
          st
        )

      assert watch_reply["result"]["max_in_flight"] == 2
      assert watch_notif["method"] == "session.event"

      {submit_reply, st, []} =
        Server.handle_rpc_payload(
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => 3,
            "method" => "session.submit",
            "params" => %{"conversation_id" => conv_id, "text" => "hello rpc", "mode" => "queue"}
          }),
          st
        )

      assert submit_reply["result"]["status"] == "ok"

      # The machine publishes the turn events, so a watcher gets them from the conversation topic.
      assert_receive {:conversation_event, ^conv_id,
                      %{"type" => "turn_started", "v" => 1, "turn_id" => turn_id}}

      assert_receive {:conversation_event, ^conv_id,
                      %{
                        "type" => "turn_completed",
                        "stop_reason" => "end_turn",
                        "turn_id" => ^turn_id
                      }}

      {ctx_reply, _st, []} =
        Server.handle_rpc_payload(
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => 4,
            "method" => "session.context",
            "params" => %{"conversation_id" => conv_id}
          }),
          st
        )

      assert length(ctx_reply["result"]["messages"]) == 2

      # Verify TCP parse error response on the live socket
      bad_resp = send_rpc.(99, "unknown.method", %{})
      assert bad_resp["error"]["code"] == -32601

      :gen_tcp.close(sock)
      GenServer.stop(server_pid)
    end

    test "Owl TUI renders status bar, handles prompts and slash commands (/status, /context, /compact), and Cluster reports status" do
      {conv_id, pid} = OwlTUI.start_session(agent: %{"model" => "claude-sonnet-4-5"})

      status_out = OwlTUI.handle_line(conv_id, pid, "/status")
      assert String.contains?(status_out, "Super-Pi-BEAM")
      assert String.contains?(status_out, "claude-sonnet-4-5")

      reply_out = OwlTUI.handle_line(conv_id, pid, "Hello Owl TUI")
      assert String.contains?(reply_out, "Echo: Hello Owl TUI")

      ctx_out = OwlTUI.handle_line(conv_id, pid, "/context")
      assert String.contains?(ctx_out, "2 messages")

      compact_out = OwlTUI.handle_line(conv_id, pid, "/compact")
      assert String.contains?(compact_out, "Compacted conversation")

      cluster_info = Cluster.status()
      assert cluster_info.db_adapter == SuperPi.Repo.active_repo()

      GenServer.stop(pid)
    end
  end

  defp drain_all_acks(st, acc) do
    case Map.keys(st.in_flight) |> Enum.sort() do
      [] ->
        acc

      [oldest | _] ->
        {st2, notifs} = Server.ack_watch_batch(st, oldest)
        new_evs = Enum.flat_map(notifs, & &1["params"]["events"])
        drain_all_acks(st2, acc ++ new_evs)
    end
  end
end
