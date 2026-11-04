defmodule SuperPi.ACPStdioTest do
  use ExUnit.Case, async: true

  test "stdio reads and writes Unicode when launched with a C locale" do
    paths = Enum.flat_map(:code.get_path(), fn path -> ["-pa", List.to_string(path)] end)

    script = """
    :io.setopts(:standard_io, encoding: :latin1)
    SuperPi.ACP.Server.run_stdio()
    IO.puts(:stdio, "café — Привіт 🌻")
    """

    {:ok, process} =
      Exile.Process.start_link(
        [System.find_executable("elixir") | paths ++ ["-e", script]],
        env: [{"LANG", "C"}, {"LC_ALL", "C"}]
      )

    id = "café — Привіт 🌻"
    request = Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => "unknown"})
    :ok = Exile.Process.write(process, request <> "\n")
    :ok = Exile.Process.close_stdin(process)
    output = read_all(process, "")
    assert {:ok, 0} = Exile.Process.await_exit(process)

    assert [reply, ^id] = String.split(output, "\n", trim: true)
    assert Jason.decode!(reply)["id"] == id
    assert String.valid?(output)
  end

  defp read_all(process, output) do
    case Exile.Process.read(process) do
      {:ok, data} -> read_all(process, output <> IO.iodata_to_binary(data))
      :eof -> output
    end
  end
end
