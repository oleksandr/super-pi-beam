defmodule SuperPi.BinScriptDefectsTest do
  @moduledoc """
  Regression tests that reproduce bin/super-pi defects found in the code review.
  The script runs against a fake `mise` that records its arguments, so no real
  mix or mise process starts. Every test is expected to FAIL on the current code
  and pass once the matching finding is fixed.

  Run only these:  mix test --only known_bug
  Skip these:      mix test --exclude known_bug
  """
  use ExUnit.Case, async: false

  @repo File.cwd!()
  @script Path.join(@repo, "bin/super-pi")

  setup do
    dir = Path.join(System.tmp_dir!(), "bin_script_#{System.unique_integer([:positive])}")
    fakebin = Path.join(dir, "fakebin")
    record = Path.join(dir, "mise_calls.log")
    File.mkdir_p!(fakebin)

    mise = Path.join(fakebin, "mise")
    File.write!(mise, "#!/bin/sh\nprintf '%s\\n' \"$@\" >> '#{record}'\nexit 0\n")
    File.chmod!(mise, 0o755)

    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir, fakebin: fakebin, record: record}
  end

  defp run(ctx, args) do
    path = ctx.fakebin <> ":" <> System.get_env("PATH", "")
    System.cmd("bash", [@script | args], cd: @repo, env: [{"PATH", path}], stderr_to_stdout: true)
  end

  defp recorded(ctx), do: if(File.exists?(ctx.record), do: File.read!(ctx.record), else: "")

  describe "arguments are interpolated into Elixir code (bin/super-pi rpc, session show)" do
    test "rpc rejects a port argument carrying code", ctx do
      marker = Path.join(ctx.dir, "pwned")
      payload = ~s|4001); System.cmd("touch", ["#{marker}"]); (1|

      {_out, status} = run(ctx, ["rpc", payload])

      assert status != 0
      assert recorded(ctx) == "", "payload reached mise: #{inspect(recorded(ctx))}"
    end

    test "rpc rejects a non-numeric port", ctx do
      {_out, status} = run(ctx, ["rpc", "abc"])

      assert status != 0
      assert recorded(ctx) == ""
    end

    test "session show rejects an ID carrying code", ctx do
      payload = ~s|1; System.halt(99); 1|

      {_out, status} = run(ctx, ["session", "show", payload])

      assert status != 0
      assert recorded(ctx) == "", "payload reached mise: #{inspect(recorded(ctx))}"
    end

    test "session show rejects a non-numeric ID", ctx do
      {_out, status} = run(ctx, ["session", "show", "abc"])

      assert status != 0
      assert recorded(ctx) == ""
    end
  end

  describe "mcp subcommand lifecycle" do
    test "does not pass --no-halt, so the VM exits when stdin reaches EOF", ctx do
      {_out, 0} = run(ctx, ["mcp"])

      calls = recorded(ctx)

      assert calls =~ "SuperPi.MCP.Server.run_stdio()",
             "mise was not invoked for mcp: #{inspect(calls)}"

      refute calls =~ "--no-halt", "VM stays alive after the MCP client closes stdin"
    end
  end
end
