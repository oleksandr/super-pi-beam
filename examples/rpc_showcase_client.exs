# Examples: External JSON-RPC 2.0 Showcase Client (`examples/rpc_showcase_client.exs`)
#
# Run with:
#   mise exec -- mix run examples/rpc_showcase_client.exs
#
# Demonstrates an external client connecting to `SuperPi.RPC.Server` over a TCP socket,
# opening a durable session, subscribing with `K = 2` ack-clocked backpressure (`session.watch`),
# submitting prompts (`session.submit`), acknowledging event batches (`session.ack`),
# inspecting derived context (`session.context`), and forking (`session.fork`).

alias SuperPi.RPC.Server

{:ok, server_pid} = Server.start_link(port: 0)
port = Server.port(server_pid)
IO.puts("==> Started SuperPi.RPC.Server on 127.0.0.1:#{port}")

{:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :line, active: false])

send_rpc = fn id, method, params ->
  payload = Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})
  :ok = :gen_tcp.send(sock, payload <> "\n")
  {:ok, line} = :gen_tcp.recv(sock, 0, 5_000)
  Jason.decode!(String.trim(line))
end

# 1. Open a durable conversation
open_resp = send_rpc.(1, "session.open", %{"agent" => %{"model" => "claude-sonnet-4-5"}})
conv_id = open_resp["result"]["conversation_id"]
IO.puts("==> Opened durable conversation ##{conv_id}")

# 2. Watch the conversation (`K = 2` ack-clocked backpressure)
watch_resp = send_rpc.(2, "session.watch", %{"conversation_id" => conv_id})
IO.puts("==> Subscribed to session.watch (max_in_flight=#{watch_resp["result"]["max_in_flight"]})")
{:ok, first_event_line} = :gen_tcp.recv(sock, 0, 5_000)
first_event = Jason.decode!(String.trim(first_event_line))
batch_id = first_event["params"]["batch_id"]
IO.puts("==> Received initial session.event batch ##{batch_id}: #{inspect(first_event["params"]["events"])}")

# 3. Acknowledge the batch
ack_resp = send_rpc.(3, "session.ack", %{"batch_id" => batch_id})
IO.puts("==> Acknowledged batch ##{ack_resp["result"]["acked"]}")

# 4. Submit a prompt
submit_resp = send_rpc.(4, "session.submit", %{"conversation_id" => conv_id, "text" => "Hello from external showcase client!", "mode" => "queue"})
IO.puts("==> Assistant response: #{inspect(submit_resp["result"]["result"])}")

:gen_tcp.close(sock)
GenServer.stop(server_pid)
