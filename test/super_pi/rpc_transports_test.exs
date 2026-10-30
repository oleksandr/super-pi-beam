defmodule SuperPi.RPCTransportsTest do
  @moduledoc "JSON-RPC over a Unix domain socket and over stdio (the TCP transport is covered elsewhere)."
  use SuperPi.DataCase, async: false
  import ExUnit.CaptureIO

  alias SuperPi.RPC.Server

  defp request(id, method, params \\ %{}) do
    Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}) <> "\n"
  end

  defp tmp_socket do
    # Unix socket paths are limited to about 100 bytes, so keep it short.
    path = Path.join("/tmp", "sp_#{System.unique_integer([:positive])}.sock")
    on_exit(fn -> File.rm(path) end)
    path
  end

  describe "unix socket" do
    test "serves a client, and the socket file is private to the owner" do
      path = tmp_socket()
      {:ok, server} = Server.start_link(socket_path: path)

      assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600

      {:ok, sock} = :gen_tcp.connect({:local, to_charlist(path)}, 0, [:binary, packet: :line, active: false])
      :ok = :gen_tcp.send(sock, request(1, "session.open"))
      {:ok, line} = :gen_tcp.recv(sock, 0, 10_000)

      assert %{"id" => 1, "result" => %{"conversation_id" => conv_id}} = Jason.decode!(line)
      assert is_integer(conv_id)

      :gen_tcp.close(sock)
      GenServer.stop(server)
    end

    test "the socket file is removed on stop, and a stale file from an earlier run is replaced" do
      path = tmp_socket()
      File.write!(path, "stale")

      {:ok, server} = Server.start_link(socket_path: path)
      {:ok, sock} = :gen_tcp.connect({:local, to_charlist(path)}, 0, [:binary, packet: :line, active: false])
      :gen_tcp.close(sock)

      GenServer.stop(server)
      refute File.exists?(path)
    end

    test "authentication applies on the socket" do
      Application.put_env(:super_pi, :gateway_tokens, alice: "tok")
      on_exit(fn -> Application.delete_env(:super_pi, :gateway_tokens) end)

      path = tmp_socket()
      {:ok, server} = Server.start_link(socket_path: path)
      {:ok, sock} = :gen_tcp.connect({:local, to_charlist(path)}, 0, [:binary, packet: :line, active: false])

      :ok = :gen_tcp.send(sock, request(1, "session.open"))
      {:ok, line} = :gen_tcp.recv(sock, 0, 10_000)
      assert %{"error" => %{"code" => -32001}} = Jason.decode!(line)

      :ok = :gen_tcp.send(sock, request(2, "auth.login", %{"token" => "tok"}))
      {:ok, line} = :gen_tcp.recv(sock, 0, 10_000)
      assert %{"result" => %{"principal" => "alice"}} = Jason.decode!(line)

      :gen_tcp.close(sock)
      GenServer.stop(server)
    end
  end

  # `StringIO`, which capture_io uses, cannot serve the default raw `IO.binread`, so these tests
  # inject a text reader. The default reader is checked by running `bin/super-pi rpc --stdio`.
  describe "stdio" do
    test "answers each request line on stdout and returns at end of input" do
      input = request(1, "session.open") <> request(2, "unknown.method")

      output = capture_io([input: input], fn -> Server.run_stdio(read_line: fn -> IO.read(:stdio, :line) end) end)
      lines = output |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

      assert [%{"id" => 1, "result" => %{"conversation_id" => _}}, %{"id" => 2, "error" => %{"code" => -32601}}] = lines
    end

    test "stdout carries only protocol lines" do
      output = capture_io([input: request(1, "session.open")], fn -> Server.run_stdio(read_line: fn -> IO.read(:stdio, :line) end) end)

      for line <- String.split(output, "\n", trim: true) do
        assert {:ok, %{"jsonrpc" => "2.0"}} = Jason.decode(line)
      end
    end

    test "a malformed line gets a parse error and the session continues" do
      output = capture_io([input: "not json\n" <> request(5, "session.open")], fn -> Server.run_stdio(read_line: fn -> IO.read(:stdio, :line) end) end)
      [first, second] = output |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

      assert first["error"]["code"] == -32700
      assert second["id"] == 5
    end
  end

  test "a new conversation gets the harness default model, not nil" do
    {:ok, server} = Server.start_link(socket_path: tmp_socket_path = tmp_socket())
    {:ok, sock} = :gen_tcp.connect({:local, to_charlist(tmp_socket_path)}, 0, [:binary, packet: :line, active: false])
    :ok = :gen_tcp.send(sock, request(1, "session.open"))
    {:ok, line} = :gen_tcp.recv(sock, 0, 10_000)
    assert %{"result" => %{"agent" => %{"model" => model}}} = Jason.decode!(line)
    assert is_binary(model)
    :gen_tcp.close(sock)
    GenServer.stop(server)
  end
end
