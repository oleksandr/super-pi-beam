defmodule SuperPi.Durable.PostgresConcurrencyTest do
  @moduledoc """
  True-concurrency tests for the task engine and sequence allocator.

  The Ecto sandbox shares one connection, so it cannot interleave transactions.
  These tests check out real connections and commit for real, so they need
  PostgreSQL and are excluded by default:

      createdb super_pi_test
      SUPER_PI_STORAGE_BACKEND=postgres DATABASE_URL=ecto://user@host/super_pi_test \\
        mix test --only postgres test/super_pi/durable/postgres_concurrency_test.exs

  They delete the rows they create.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias SuperPi.Durable.{Storage, TaskEngine}
  alias SuperPi.Durable.Schemas.Conversation
  alias SuperPi.Durable.Schemas.Task, as: TaskSchema
  alias SuperPi.Repo

  @moduletag :postgres

  if Application.compile_env(:super_pi, :storage_backend, :sqlite) != :postgres do
    @moduletag skip: "needs SUPER_PI_STORAGE_BACKEND=postgres"
  end

  setup_all do
    repo = Repo.active_repo()
    Ecto.Adapters.SQL.Sandbox.mode(repo, :auto)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.mode(repo, :manual) end)
    :ok
  end

  setup do
    conv = Storage.create_conversation!()

    on_exit(fn ->
      Repo.delete_all(from t in TaskSchema, where: t.conversation_id == ^conv.id)
      Repo.delete_all(from c in Conversation, where: c.id == ^conv.id)
    end)

    %{conv: conv}
  end

  test "concurrent next_seq! calls never repeat a number" do
    seqs =
      1..100
      |> Task.async_stream(fn _ -> Storage.next_seq!() end, max_concurrency: 20, timeout: 30_000)
      |> Enum.map(fn {:ok, seq} -> seq end)

    assert length(Enum.uniq(seqs)) == 100
  end

  test "exactly one of many concurrent start_task calls wins", %{conv: conv} do
    for _ <- 1..10 do
      {:ok, task} = TaskEngine.create_task(conv.id, "pi.generation")

      results =
        1..8
        |> Task.async_stream(fn _ -> TaskEngine.start_task(task.id) end, max_concurrency: 8, timeout: 30_000)
        |> Enum.map(fn {:ok, r} -> r end)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1, "results: #{inspect(results)}"
    end
  end

  test "a child settling while the parent starts waiting never leaves the parent stuck", %{conv: conv} do
    for i <- 1..60 do
      {:ok, parent} = TaskEngine.create_task(conv.id, "parent")
      {:ok, child} = TaskEngine.create_task(conv.id, "child", %{}, owner_task_id: parent.id)
      {:ok, _} = TaskEngine.start_task(parent.id)
      {:ok, _} = TaskEngine.start_task(child.id)

      waiter = Task.async(fn -> TaskEngine.wait_for_children(parent.id, [child.id]) end)
      completer = Task.async(fn -> TaskEngine.complete_task(child.id, %{}) end)

      assert {:ok, _} = Task.await(waiter, 30_000)
      assert {:ok, _} = Task.await(completer, 30_000)

      final = Repo.get!(TaskSchema, parent.id)
      refute final.status == "waiting", "iteration #{i}: parent stuck waiting on a settled child"
    end
  end

  test "completing a child while the parent is aborted does not deadlock", %{conv: conv} do
    for i <- 1..40 do
      {:ok, parent} = TaskEngine.create_task(conv.id, "parent")
      {:ok, child} = TaskEngine.create_task(conv.id, "child", %{}, owner_task_id: parent.id)
      {:ok, _} = TaskEngine.start_task(parent.id)
      {:ok, _} = TaskEngine.start_task(child.id)

      tasks = [
        Task.async(fn -> safe(fn -> TaskEngine.complete_task(child.id, %{}) end) end),
        Task.async(fn -> safe(fn -> TaskEngine.abort_task!(parent.id) end) end)
      ]

      for result <- Enum.map(tasks, &Task.await(&1, 30_000)) do
        refute match?({:raised, %Postgrex.Error{postgres: %{code: :deadlock_detected}}}, result),
               "iteration #{i}: deadlock"
      end
    end
  end

  defp safe(fun) do
    {:ok, fun.()}
  rescue
    e -> {:raised, e}
  end

  test "a write to a shared-workspace file waits for the cross-node advisory lock" do
    path = Path.join(System.tmp_dir!(), "shared_lock_#{System.unique_integer([:positive])}.txt")
    on_exit(fn -> File.rm(path) end)
    parent = self()

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.query!("SELECT pg_advisory_xact_lock($1)", [SuperPi.Env.Shared.lock_key(path)])
          send(parent, :locked)

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive :locked, 5_000
    writer = Task.async(fn -> SuperPi.Env.Shared.write_file(path, "x", []) end)

    assert Task.yield(writer, 400) == nil, "the write did not wait for the lock"
    refute File.exists?(path)

    send(holder.pid, :release)
    assert :ok = Task.await(writer, 10_000)
    Task.await(holder)
    assert File.read!(path) == "x"
  end

  test "concurrent edits of one shared file lose no update" do
    path = Path.join(System.tmp_dir!(), "shared_edit_#{System.unique_integer([:positive])}.txt")
    File.write!(path, Enum.map_join(1..20, "", &"line-#{&1}\n"))
    on_exit(fn -> File.rm(path) end)

    1..20
    |> Task.async_stream(
      fn i -> SuperPi.Env.Shared.edit_file(path, "line-#{i}\n", "done-#{i}\n", []) end,
      max_concurrency: 10,
      timeout: 30_000
    )
    |> Enum.each(fn {:ok, result} -> assert match?({:ok, _}, result), inspect(result) end)

    lines = path |> File.read!() |> String.split("\n", trim: true)
    assert length(lines) == 20
    assert Enum.count(lines, &String.starts_with?(&1, "done-")) == 20, "updates were lost: #{inspect(lines)}"
  end
end
