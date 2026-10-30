defmodule SuperPi.WorkspaceTest do
  @moduledoc "Workspace kinds, capabilities, confinement, scratch lifecycle and the artifact store (Task 46)."
  use SuperPi.DataCase, async: false

  import Ecto.Query

  alias SuperPi.Artifacts
  alias SuperPi.Conversation.Machine
  alias SuperPi.Durable.{Storage, TaskEngine}
  alias SuperPi.Durable.Schemas.Conversation
  alias SuperPi.Env.Workspace
  alias SuperPi.TestSupport.Faults
  alias SuperPi.Tools

  setup do
    base = Path.join(System.tmp_dir!(), "ws_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)
    Application.put_env(:super_pi, :scratch_dir, Path.join(base, "scratch"))
    on_exit(fn -> Application.delete_env(:super_pi, :scratch_dir) end)
    %{base: base}
  end

  defp conv!(workspace, extra \\ %{}) do
    Storage.create_conversation!(
      agent: Map.merge(%{"workspace" => workspace, "executionMode" => "auto"}, extra)
    )
  end

  defp run(conv, tool, args, extra_ctx \\ %{}),
    do: Tools.execute(tool, args, Map.merge(%{conversation_id: conv.id}, extra_ctx))

  describe "local (default)" do
    test "behaves as before: absolute paths anywhere, bash in the cwd", %{base: base} do
      conv = Storage.create_conversation!()
      file = Path.join(base, "a.txt")
      File.write!(file, "hello")

      assert run(conv, "read", %{"path" => file})["output"] =~ "hello"

      assert run(conv, "write", %{"path" => Path.join(base, "b.txt"), "content" => "x"})[
               "is_error"
             ] != true

      assert File.read!(Path.join(base, "b.txt")) == "x"
    end

    test "artifact tools are refused unless the workspace asks for them" do
      conv = Storage.create_conversation!()
      res = run(conv, "artifact_list", %{})
      assert res["is_error"]
      assert res["output"] =~ "not available in a local workspace"

      conv2 = conv!(%{"kind" => "local", "artifacts" => true})
      refute run(conv2, "artifact_list", %{})["is_error"]
    end
  end

  describe "shared" do
    setup %{base: base} do
      root = Path.join(base, "shared")
      File.mkdir_p!(root)
      File.write!(Path.join(root, "in.txt"), "inside")
      %{root: root, conv: conv!(%{"kind" => "shared", "root" => root})}
    end

    test "relative paths resolve against the root", %{root: root, conv: conv} do
      assert run(conv, "read", %{"path" => "in.txt"})["output"] =~ "inside"
      run(conv, "write", %{"path" => "sub/out.txt", "content" => "written"})
      assert File.read!(Path.join(root, "sub/out.txt")) == "written"
    end

    test "a path outside the root is refused, absolute or with ..", %{base: base, conv: conv} do
      outside = Path.join(base, "secret.txt")
      File.write!(outside, "secret")

      for path <- [outside, "../secret.txt", "sub/../../secret.txt"] do
        res = run(conv, "read", %{"path" => path})
        assert res["is_error"], "#{path} was read"
        assert res["output"] =~ "outside the workspace"
      end

      refute File.exists?(Path.join(base, "evil.txt"))

      assert run(conv, "write", %{"path" => Path.join(base, "evil.txt"), "content" => "x"})[
               "is_error"
             ]

      refute File.exists?(Path.join(base, "evil.txt"))
    end

    test "a symlink inside the root cannot lead out of it", %{base: base, root: root, conv: conv} do
      File.write!(Path.join(base, "secret.txt"), "secret")
      File.ln_s!(base, Path.join(root, "link"))

      assert run(conv, "read", %{"path" => "link/secret.txt"})["is_error"]
      assert run(conv, "read", %{"path" => "link/../shared/in.txt"})["is_error"]
    end

    test "bash starts in the root; ls, grep and find work inside it", %{root: root, conv: conv} do
      assert run(conv, "bash", %{"command" => "pwd"})["output"]
             |> String.trim()
             |> Path.basename() == "shared"

      assert run(conv, "ls", %{})["output"] =~ "in.txt"
      assert run(conv, "grep", %{"pattern" => "inside"})["output"] =~ "in.txt"
      assert run(conv, "find", %{})["output"] =~ "in.txt"
      assert run(conv, "ls", %{"path" => "/"})["is_error"]
      assert File.exists?(root)
    end

    test "a cd inside the root is allowed and one outside is not", %{root: root, conv: conv} do
      File.mkdir_p!(Path.join(root, "d"))
      File.write!(Path.join(root, "d/x.txt"), "in d")
      assert run(conv, "read", %{"path" => "x.txt", "cd" => "d"})["output"] =~ "in d"
      assert run(conv, "bash", %{"command" => "pwd", "cd" => "/"})["is_error"]
    end

    test "a missing or relative root is an error, never the local disk" do
      assert run(conv!(%{"kind" => "shared"}), "read", %{"path" => "mix.exs"})["output"] =~
               "needs a root"

      assert run(conv!(%{"kind" => "shared", "root" => "relative/dir"}), "read", %{"path" => "x"})[
               "output"
             ] =~ "absolute root"
    end
  end

  describe "scratch" do
    test "is created per task under the base and is confined", %{base: base} do
      conv = conv!(%{"kind" => "scratch"})
      {:ok, task} = TaskEngine.create_task(conv.id, "pi.generation")

      res =
        run(conv, "write", %{"path" => "notes.txt", "content" => "n"}, %{active_task_id: task.id})

      refute res["is_error"]
      dir = Path.join([base, "scratch", to_string(conv.id), "task-#{task.id}"])
      assert File.read!(Path.join(dir, "notes.txt")) == "n"

      assert run(conv, "read", %{"path" => "/etc/hosts"}, %{active_task_id: task.id})["is_error"]
    end

    test "cleanup removes the task directory", %{base: base} do
      conv = conv!(%{"kind" => "scratch"})
      {:ok, task} = TaskEngine.create_task(conv.id, "pi.generation")
      run(conv, "write", %{"path" => "a", "content" => "1"}, %{active_task_id: task.id})
      dir = Path.join([base, "scratch", to_string(conv.id), "task-#{task.id}"])
      assert File.dir?(dir)

      Workspace.cleanup_scratch(conv.id, task.id)
      refute File.exists?(dir)
    end

    test "lifetime conversation survives task cleanup", %{base: base} do
      conv = conv!(%{"kind" => "scratch", "lifetime" => "conversation"})
      {:ok, task} = TaskEngine.create_task(conv.id, "pi.generation")
      run(conv, "write", %{"path" => "keep", "content" => "1"}, %{active_task_id: task.id})
      Workspace.cleanup_scratch(conv.id, task.id)

      assert File.exists?(
               Path.join([base, "scratch", to_string(conv.id), "_conversation", "keep"])
             )
    end

    test "a restarted task is told its scratch is new, once" do
      conv = conv!(%{"kind" => "scratch"})
      {:ok, task} = TaskEngine.create_task(conv.id, "pi.generation")

      Repo.update_all(from(t in SuperPi.Durable.Schemas.Task, where: t.id == ^task.id),
        set: [attempt: 1]
      )

      first = run(conv, "write", %{"path" => "a", "content" => "1"}, %{active_task_id: task.id})
      assert first["output"] =~ "scratch workspace is new and empty"
      second = run(conv, "read", %{"path" => "a"}, %{active_task_id: task.id})
      refute second["output"] =~ "new and empty"
    end

    test "the sweep removes directories of finished tasks and keeps running ones", %{base: base} do
      conv = conv!(%{"kind" => "scratch"})
      {:ok, done} = TaskEngine.create_task(conv.id, "pi.generation")
      {:ok, live} = TaskEngine.create_task(conv.id, "pi.generation")
      {:ok, _} = TaskEngine.start_task(done.id)
      {:ok, _} = TaskEngine.complete_task(done.id, %{})
      {:ok, _} = TaskEngine.start_task(live.id)

      for t <- [done, live],
          do: run(conv, "write", %{"path" => "a", "content" => "1"}, %{active_task_id: t.id})

      assert Workspace.sweep() >= 1
      refute File.exists?(Path.join([base, "scratch", to_string(conv.id), "task-#{done.id}"]))
      assert File.exists?(Path.join([base, "scratch", to_string(conv.id), "task-#{live.id}"]))
    end
  end

  describe "none and capabilities" do
    test "no file or command tools, only artifacts" do
      conv = conv!(%{"kind" => "none"})

      for tool <- ["read", "write", "edit", "bash", "grep", "find", "ls"] do
        res =
          run(conv, tool, %{
            "path" => "x",
            "command" => "echo hi",
            "pattern" => "x",
            "content" => "x",
            "old_text" => "a",
            "new_text" => "b"
          })

        assert res["output"] =~ "not available in a none workspace", tool
      end

      refute run(conv, "artifact_list", %{})["is_error"]
    end

    test "unknown kinds and malformed workspaces are errors" do
      assert run(conv!(%{"kind" => "tmpfs"}), "read", %{"path" => "x"})["output"] =~
               "unknown workspace kind"

      assert run(conv!("nonsense"), "read", %{"path" => "x"})["output"] =~
               "workspace must be a map"
    end

    test "offered_tools removes what the workspace cannot serve and adds artifact tools" do
      all = Enum.map(["read", "write", "bash", "ls"], &%{"name" => &1})

      names = fn cfg ->
        cfg |> then(&Workspace.offered_tools(all, %{"workspace" => &1})) |> Enum.map(& &1["name"])
      end

      assert names.(%{"kind" => "none"}) |> Enum.sort() == [
               "artifact_get",
               "artifact_list",
               "artifact_put"
             ]

      assert "bash" in names.(%{"kind" => "scratch"}) and
               "artifact_put" in names.(%{"kind" => "scratch"})

      assert names.(%{"kind" => "local"}) == ["read", "write", "bash", "ls"]
      assert "artifact_put" in names.(%{"kind" => "local", "artifacts" => true})
      # Calling it twice does not duplicate the artifact tools.
      twice =
        Workspace.offered_tools(
          Workspace.offered_tools(all, %{"workspace" => %{"kind" => "none"}}),
          %{"workspace" => %{"kind" => "none"}}
        )

      assert length(twice) == 3
    end
  end

  describe "artifacts" do
    setup %{base: base} do
      root = Path.join(base, "w")
      File.mkdir_p!(root)
      %{root: root, conv: conv!(%{"kind" => "shared", "root" => root})}
    end

    test "put, get, list and replace", %{conv: conv} do
      assert %{"output" => "Saved artifact reports/a.md (5 bytes)."} =
               run(conv, "artifact_put", %{"name" => "reports/a.md", "content" => "hello"})

      assert run(conv, "artifact_get", %{"name" => "reports/a.md"})["output"] == "hello"
      run(conv, "artifact_put", %{"name" => "reports/a.md", "content" => "replaced!"})
      assert run(conv, "artifact_get", %{"name" => "reports/a.md"})["output"] == "replaced!"
      assert run(conv, "artifact_list", %{})["output"] =~ "reports/a.md  9 bytes"
      assert length(Artifacts.list(conv.id)) == 1
    end

    test "path saves a workspace file and to_path restores it", %{root: root, conv: conv} do
      File.write!(Path.join(root, "src.txt"), "from file")
      run(conv, "artifact_put", %{"name" => "kept", "path" => "src.txt"})
      File.rm!(Path.join(root, "src.txt"))

      assert run(conv, "artifact_get", %{"name" => "kept", "to_path" => "restored/src.txt"})[
               "output"
             ] =~ "Wrote artifact kept"

      assert File.read!(Path.join(root, "restored/src.txt")) == "from file"
    end

    test "to_path outside a confined workspace is refused", %{base: base, conv: conv} do
      run(conv, "artifact_put", %{"name" => "kept", "content" => "x"})

      res =
        run(conv, "artifact_get", %{"name" => "kept", "to_path" => Path.join(base, "escape.txt")})

      assert res["is_error"]
      refute File.exists?(Path.join(base, "escape.txt"))
    end

    test "a workspace without a filesystem cannot use path or to_path" do
      conv = conv!(%{"kind" => "none"})
      run(conv, "artifact_put", %{"name" => "n", "content" => "x"})

      assert run(conv, "artifact_put", %{"name" => "m", "path" => "x"})["structured_output"][
               "status"
             ] == "failed"

      assert run(conv, "artifact_get", %{"name" => "n", "to_path" => "x"})["structured_output"][
               "status"
             ] == "workspace_unsupported"

      assert run(conv, "artifact_get", %{"name" => "n"})["output"] == "x"
    end

    test "invalid names are refused", %{conv: conv} do
      for name <- [
            "",
            "/abs",
            "a/../b",
            "..",
            "a//b",
            "has space",
            "x" |> String.duplicate(201),
            "a/./b",
            "back\\slash"
          ] do
        res = run(conv, "artifact_put", %{"name" => name, "content" => "x"})
        assert res["structured_output"]["status"] == "invalid_name", inspect(name)
      end
    end

    test "size and count limits", %{conv: conv} do
      Application.put_env(:super_pi, :artifact_max_bytes, 10)
      Application.put_env(:super_pi, :artifact_max_count, 2)

      on_exit(fn ->
        Application.delete_env(:super_pi, :artifact_max_bytes) &&
          Application.delete_env(:super_pi, :artifact_max_count)
      end)

      assert run(conv, "artifact_put", %{"name" => "big", "content" => String.duplicate("x", 11)})[
               "structured_output"
             ]["status"] == "too_large"

      run(conv, "artifact_put", %{"name" => "a", "content" => "1"})
      run(conv, "artifact_put", %{"name" => "b", "content" => "1"})

      assert run(conv, "artifact_put", %{"name" => "c", "content" => "1"})["structured_output"][
               "status"
             ] == "too_many"

      # Replacing an existing artifact is not a new one.
      refute run(conv, "artifact_put", %{"name" => "a", "content" => "2"})["is_error"]
    end

    test "artifacts belong to one conversation", %{conv: conv} do
      other = conv!(%{"kind" => "scratch"})
      run(conv, "artifact_put", %{"name" => "mine", "content" => "x"})

      assert run(other, "artifact_get", %{"name" => "mine"})["structured_output"]["status"] ==
               "not_found"

      assert Artifacts.list(other.id) == []
    end

    test "binary and large artifacts are not returned inline", %{conv: conv} do
      {:ok, _} = Artifacts.put(conv.id, "bin", <<0, 159, 146, 150>>, "application/octet-stream")

      assert run(conv, "artifact_get", %{"name" => "bin"})["structured_output"]["status"] ==
               "binary"

      {:ok, _} = Artifacts.put(conv.id, "big", String.duplicate("a", 200_000), "text/plain")

      assert run(conv, "artifact_get", %{"name" => "big"})["structured_output"]["status"] ==
               "too_large_to_return"
    end

    test "deleting the conversation deletes its artifacts", %{conv: conv} do
      run(conv, "artifact_put", %{"name" => "gone", "content" => "x"})
      Repo.delete_all(from(c in Conversation, where: c.id == ^conv.id))
      assert Artifacts.list(conv.id) == []
    end

    test "missing content is reported", %{conv: conv} do
      assert run(conv, "artifact_put", %{"name" => "n"})["structured_output"]["status"] ==
               "invalid_arguments"
    end
  end

  describe "through a conversation" do
    test "a none workspace offers only artifact tools to the model" do
      conv = conv!(%{"kind" => "none"}, %{"tools" => Tools.active_llm_tools()})
      me = self()

      responder = fn payload, _ctx ->
        send(me, {:tools, payload.tools |> Enum.map(& &1["name"]) |> Enum.sort()})
        {:ok, Faults.text_msg("ok")}
      end

      {:ok, pid} =
        Machine.start_link(conversation_id: conv.id, extensions: [], llm_responder: responder)

      {:ok, _} = Machine.submit(pid, "hi", timeout: 10_000)
      assert_received {:tools, names}

      # Other tests may register tools in the global catalog, so check what must and must not be there.
      for tool <- ["artifact_get", "artifact_list", "artifact_put"], do: assert(tool in names)

      for tool <- ["read", "write", "edit", "bash", "grep", "find", "ls"],
          do: refute(tool in names)
    end

    test "the scratch directory is removed when the turn ends", %{base: base} do
      conv = conv!(%{"kind" => "scratch"}, %{"tools" => Tools.active_llm_tools()})
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      responder = fn _p, _c ->
        case Agent.get_and_update(calls, &{&1, &1 + 1}) do
          0 ->
            {:ok,
             Faults.tool_call_msg("w1", "write", %{"path" => "scratch.txt", "content" => "temp"})}

          _ ->
            {:ok, Faults.text_msg("done")}
        end
      end

      {:ok, pid} =
        Machine.start_link(conversation_id: conv.id, extensions: [], llm_responder: responder)

      {:ok, _} = Machine.submit(pid, "write a file", timeout: 10_000)

      # The reply is sent before the machine enters :idle, where the cleanup runs.
      pattern = Path.join([base, "scratch", to_string(conv.id), "task-*"])

      gone? =
        Enum.any?(1..50, fn _ ->
          Path.wildcard(pattern) == [] or (Process.sleep(20) && false)
        end)

      assert gone?, "scratch directory still there: #{inspect(Path.wildcard(pattern))}"
    end
  end
end
