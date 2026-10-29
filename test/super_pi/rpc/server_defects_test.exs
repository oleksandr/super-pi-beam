defmodule SuperPi.RPC.ServerDefectsTest do
  @moduledoc """
  Regression tests that reproduce RPC defects found in the code review
  (see vault note "20 - Codebase Review Findings"). Every test is expected to
  FAIL on the current code and pass once the matching finding is fixed.

  Run only these:  mix test --only known_bug
  Skip these:      mix test --exclude known_bug
  """
  use SuperPi.DataCase, async: false

  alias SuperPi.RPC.Server

  @moduletag :known_bug

  defp non_loopback_ipv4 do
    case :inet.getifaddrs() do
      {:ok, ifaces} ->
        ifaces
        |> Enum.flat_map(fn {_name, opts} -> Keyword.get_values(opts, :addr) end)
        |> Enum.find(fn
          {127, _, _, _} -> false
          {169, 254, _, _} -> false
          {_, _, _, _} -> true
          _ -> false
        end)

      _ ->
        nil
    end
  end

  describe "C2: RPC listener binds all interfaces without authentication (rpc/server.ex:152)" do
    test "server does not accept TCP connections on a non-loopback address" do
      case non_loopback_ipv4() do
        nil ->
          IO.puts("\n  [skipped] no non-loopback IPv4 address on this host")

        ip ->
          {:ok, server_pid} = Server.start_link(port: 0)
          port = Server.port(server_pid)

          result = :gen_tcp.connect(ip, port, [:binary, active: false], 1_000)

          case result do
            {:ok, sock} ->
              :gen_tcp.close(sock)
              flunk("RPC server accepted a connection on #{inspect(ip)}:#{port}; it must bind to loopback only")

            {:error, _reason} ->
              :ok
          end
      end
    end
  end

  describe "malformed requests must produce JSON-RPC errors, not raise (rpc/server.ex:240-470)" do
    # {label, method, params}
    @bad_requests [
      {"params is null", "session.submit", nil},
      {"params is a list", "session.submit", []},
      {"submit without conversation_id", "session.submit", %{"text" => "hi"}},
      {"submit without text", "session.submit", %{"conversation_id" => 1}},
      {"submit with non-integer conversation_id", "session.submit", %{"conversation_id" => "abc", "text" => "hi"}},
      {"watch without conversation_id", "session.watch", %{}},
      {"ack with non-integer batch_id", "session.ack", %{"batch_id" => "x"}},
      {"open with non-map agent", "session.open", %{"agent" => "not-a-map"}}
    ]

    for {label, method, params} <- @bad_requests do
      test "#{label}: #{method}" do
        payload =
          Jason.encode!(%{"jsonrpc" => "2.0", "id" => 7, "method" => unquote(method), "params" => unquote(Macro.escape(params))})

        outcome =
          try do
            {:ok, Server.handle_rpc_payload(payload, Server.new_client_state())}
          rescue
            e -> {:raised, e}
          end

        assert {:ok, {reply, _state, _notifs}} = outcome,
               "handle_rpc_payload raised: #{inspect(outcome)}"

        assert is_map(reply) and is_map(reply["error"]), "expected a JSON-RPC error reply, got: #{inspect(reply)}"
        assert reply["error"]["code"] in [-32602, -32603]
      end
    end

    test "request without id is a notification and gets no reply" do
      payload =
        Jason.encode!(%{"jsonrpc" => "2.0", "method" => "session.open", "params" => %{"agent" => %{}}})

      {reply, _state, _notifs} = Server.handle_rpc_payload(payload, Server.new_client_state())

      assert reply == nil, "JSON-RPC 2.0 forbids replying to notifications, got: #{inspect(reply)}"
    end
  end
end
