defmodule SuperPi.Properties.PermissionsBoundaryTest do
  @moduledoc """
  Properties of the workspace boundary and the `permissions.deny` list.

  The boundary oracle is the operating system: `realpath` resolves each generated path, and the
  path must be allowed if and only if the result is inside the workspace. The generated paths
  mix `..`, `.` and a symlink that leads out of the workspace, so a lexical check that collapses
  `..` before it follows the link gives the wrong answer.
  """
  use SuperPi.DataCase, async: false
  use ExUnitProperties

  alias SuperPi.Durable.Storage
  alias SuperPi.Plugins.Permissions

  @tools ["read", "write", "edit", "ls", "grep", "find"]

  setup_all do
    base = Path.join(System.tmp_dir!(), "perm_props_#{System.unique_integer([:positive])}")
    ws = Path.join(base, "ws")

    for dir <- [
          Path.join([ws, "a"]),
          Path.join([ws, "b", "c"]),
          Path.join(base, "outside"),
          Path.join(base, "ws-evil")
        ] do
      File.mkdir_p!(dir)
    end

    File.ln_s!(Path.join(base, "outside"), Path.join(ws, "link"))
    File.ln_s!(Path.join(ws, "a"), Path.join(ws, "inlink"))

    on_exit(fn -> File.rm_rf!(base) end)
    {real_ws, 0} = System.cmd("realpath", [ws])
    %{base: base, ws: ws, real_ws: String.trim(real_ws)}
  end

  defp conversation!(ws, mode, extra \\ %{}) do
    app = Path.join(System.tmp_dir!(), "perm_app_#{System.unique_integer([:positive])}")
    File.mkdir_p!(app)
    on_exit(fn -> File.rm_rf(app) end)

    Storage.create_conversation!(
      agent:
        Map.merge(
          %{"workspacePaths" => [ws], "appDataDir" => app, "executionMode" => mode},
          extra
        )
    )
  end

  defp verdict(conv, tool, path) do
    case Permissions.before_tool(tool, %{"path" => path}, %{conversation_id: conv.id}) do
      :allow -> :allow
      {:block, _} -> :block
    end
  end

  # Relative step list. Names that do not exist in the current directory make the path invalid,
  # and the property skips invalid paths.
  defp steps do
    step =
      frequency([
        {4, member_of(["a", "b", "c", "x"])},
        {3, member_of(["link", "inlink"])},
        {4, constant("..")},
        {1, constant(".")}
      ])

    list_of(step, min_length: 1, max_length: 8)
  end

  defp inside?(real, real_ws), do: real == real_ws or String.starts_with?(real, real_ws <> "/")

  property "a path is allowed if and only if the operating system resolves it inside the workspace",
           ctx do
    conv = conversation!(ctx.ws, "auto")

    check all(steps <- steps(), tool <- member_of(@tools), max_runs: 300) do
      path = Path.join([ctx.ws | steps])

      case System.cmd("realpath", [path], stderr_to_stdout: true) do
        {real, 0} ->
          expected = if inside?(String.trim(real), ctx.real_ws), do: :allow, else: :block

          assert verdict(conv, tool, path) == expected,
                 "path #{path} resolves to #{String.trim(real)}"

        _ ->
          :ok
      end
    end
  end

  property "going up from the outbound link leaves the workspace", ctx do
    conv = conversation!(ctx.ws, "auto")

    check all(ups <- integer(1..3), tool <- member_of(@tools), max_runs: 30) do
      path = Path.join([ctx.ws, "link" | List.duplicate("..", ups)])
      assert verdict(conv, tool, path) == :block
    end
  end

  property "a path through the outbound link is always blocked", ctx do
    conv = conversation!(ctx.ws, "auto")

    check all(
            rest <- list_of(member_of(["x", "y", "z.txt"]), max_length: 3),
            tool <- member_of(@tools),
            max_runs: 50
          ) do
      path = Path.join([ctx.ws, "link" | rest])
      assert verdict(conv, tool, path) == :block
    end
  end

  property "a sibling directory that shares the workspace name prefix is always blocked", ctx do
    conv = conversation!(ctx.ws, "auto")

    check all(
            rest <- list_of(member_of(["x", "y", "z.txt"]), max_length: 3),
            tool <- member_of(@tools),
            max_runs: 50
          ) do
      assert verdict(conv, tool, Path.join([ctx.base, "ws-evil" | rest])) == :block
    end
  end

  property "the boundary verdict does not depend on the mode, except that plan also blocks edits",
           ctx do
    convs = Map.new(["plan", "accept-edits", "auto"], &{&1, conversation!(ctx.ws, &1)})

    check all(steps <- steps(), max_runs: 150) do
      path = Path.join([ctx.ws | steps])

      case System.cmd("realpath", [path], stderr_to_stdout: true) do
        {_, 0} ->
          assert verdict(convs["plan"], "read", path) == verdict(convs["auto"], "read", path)

          assert verdict(convs["accept-edits"], "read", path) ==
                   verdict(convs["auto"], "read", path)

          assert verdict(convs["plan"], "write", path) == :block

        _ ->
          :ok
      end
    end
  end

  # --- permissions.deny ---

  @wrappers [
    "",
    "sudo ",
    "env ",
    "env FOO=1 ",
    "nohup ",
    "time ",
    "/usr/bin/",
    "xargs ",
    "command "
  ]
  @ops [" && ", " || ", "; ", " | ", "\n"]
  @args ["", " http://example.com", " -s -o /dev/null", " --version"]
  @filler ["echo hi", "ls -la", "git status", "true", "cat file.txt"]

  defp deny_conv(ws),
    do:
      conversation!(ws, "auto", %{
        "settingsOverride" => %{"permissions" => %{"deny" => ["command(curl)"]}}
      })

  defp bash(conv, cmd),
    do: Permissions.before_tool("bash", %{"command" => cmd}, %{conversation_id: conv.id})

  property "a denied command is blocked however it is chained or wrapped", ctx do
    conv = deny_conv(ctx.ws)

    check all(
            before <- member_of(@filler),
            op1 <- member_of(@ops),
            wrapper <- member_of(@wrappers),
            args <- member_of(@args),
            op2 <- member_of(@ops),
            after_ <- member_of(@filler),
            form <- member_of([:plain, :subshell, :backtick, :quoted, :bash_c, :single_quoted]),
            max_runs: 400
          ) do
      invocation = wrapper <> "curl" <> args

      body =
        case form do
          :plain -> invocation
          :subshell -> "echo $(" <> invocation <> ")"
          :backtick -> "echo `" <> invocation <> "`"
          :quoted -> ~s(sh -c "#{invocation}")
          :single_quoted -> "sh -c '#{invocation}'"
          :bash_c -> "bash -c '#{invocation}'"
        end

      cmd = before <> op1 <> body <> op2 <> after_
      assert {:block, _} = bash(conv, cmd), "not blocked: #{inspect(cmd)}"
    end
  end

  property "a command that never names the denied word as a word is allowed", ctx do
    conv = deny_conv(ctx.ws)

    check all(
            words <-
              list_of(
                one_of([
                  member_of([
                    "curlish",
                    "mycurl",
                    "curl2",
                    "curl.sh",
                    "recurl",
                    "ls",
                    "echo",
                    "git",
                    "-la",
                    "file.txt"
                  ]),
                  string(:alphanumeric, min_length: 1, max_length: 8)
                ]),
                min_length: 1,
                max_length: 6
              ),
            op <- member_of(@ops),
            max_runs: 300
          ) do
      words = Enum.reject(words, &(&1 == "curl"))
      cmd = Enum.join(words, " ") <> op <> Enum.join(words, " ")
      assert :allow = bash(conv, cmd)
    end
  end

  property "a multi-word deny pattern needs its words in a row", ctx do
    conv =
      conversation!(ctx.ws, "auto", %{
        "settingsOverride" => %{"permissions" => %{"deny" => ["command(git push)"]}}
      })

    check all(flag <- member_of(["", " --force", " origin main"]), max_runs: 30) do
      assert {:block, _} = bash(conv, "git push" <> flag)
      assert {:block, _} = bash(conv, "cd x && git push" <> flag)
      assert :allow = bash(conv, "git status && echo push")
      assert :allow = bash(conv, "git pull" <> flag)
    end
  end
end
