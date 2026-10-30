defmodule SuperPi.ScheduleTest do
  @moduledoc """
  The scheduler: tools, tick, exactly-once claim, run modes, failure accounting and the loop
  guard. Oban runs in `testing: :manual`, so ticks and runs are driven by calling the workers.
  """
  use SuperPi.DataCase, async: false

  @moduletag :capture_log

  alias SuperPi.Durable.{Doc, Storage, TaskEngine}
  alias SuperPi.Durable.Schemas.{Conversation, Schedule}
  alias SuperPi.Durable.Schemas.Task, as: TaskSchema
  alias SuperPi.Plugins.Scheduler
  alias SuperPi.Schedule, as: Sched
  alias SuperPi.Workers.{ScheduleRunWorker, ScheduleTickWorker}

  setup do
    # Most tests store the run and stop there; the ones that run a turn start the machine.
    Application.put_env(:super_pi, :scheduler_autostart, false)
    on_exit(fn -> Application.delete_env(:super_pi, :scheduler_autostart) end)
    :ok
  end

  defp conversation!(agent \\ %{}) do
    conv = Storage.create_conversation!(agent: Map.merge(%{"model" => "m"}, agent))

    Storage.append_entry!(conv.id, "pi.message", %{
      "role" => "user",
      "content" => [%{"type" => "text", "text" => "hello"}]
    })

    conv
  end

  defp ctx(conv, extra \\ %{}), do: Map.merge(%{conversation_id: conv.id, config: []}, extra)

  defp tool(name, args, conv, extra \\ %{}),
    do: Scheduler.wrap_tool(name, args, fn _ -> flunk("fell through") end, ctx(conv, extra))

  defp create!(conv, attrs \\ %{}) do
    {:ok, schedule, _token} =
      Sched.create(
        Map.merge(%{conversation_id: conv.id, prompt: "do it", cron: "0 7 * * *"}, attrs)
      )

    schedule
  end

  # A fixed "now", so the tick minute never lines up with a test expression by chance.
  @now ~U[2026-10-30 12:03:00Z]
  defp minute(offset_min \\ 0), do: DateTime.add(@now, offset_min * 60, :second)

  defp set!(schedule, fields),
    do: Repo.update_all(from(s in Schedule, where: s.id == ^schedule.id), set: fields)

  defp reload(schedule), do: Repo.get!(Schedule, schedule.id)

  defp run_jobs,
    do:
      Repo.all(
        from(j in Oban.Job,
          where: j.worker == "SuperPi.Workers.ScheduleRunWorker",
          order_by: j.id
        )
      )

  defp tasks(conv_id),
    do:
      Repo.all(
        from(t in TaskSchema,
          where: t.conversation_id == ^conv_id and t.kind == "pi.generation",
          order_by: t.id
        )
      )

  defp all_run_tasks,
    do: Repo.all(from(t in TaskSchema, where: t.kind == "pi.generation", order_by: t.id))

  defp eventually(fun, tries \\ 400) do
    cond do
      fun.() ->
        :ok

      tries == 0 ->
        flunk("condition never held")

      true ->
        Process.sleep(10)
        eventually(fun, tries - 1)
    end
  end

  defp fail_task!(conv_id, schedule, error \\ "boom") do
    {:ok, task} =
      TaskEngine.create_task(conv_id, "pi.generation", %{"schedule_id" => schedule.id})

    {:ok, running} = TaskEngine.start_task(task.id)
    TaskEngine.fail_task(running.id, error)
    set!(schedule, last_task_id: task.id)
    task
  end

  describe "tools" do
    test "specs are appended to the conversation's tools, once, with effects, and are not in the global catalog" do
      {:ok, cfg} = Scheduler.before_agent_start(%{"tools" => [%{"name" => "x"}]}, ctx(%{id: 1}))
      {:ok, again} = Scheduler.before_agent_start(cfg, ctx(%{id: 1}))

      assert Enum.map(cfg["tools"], & &1["name"]) == [
               "x",
               "schedule_create",
               "schedule_list",
               "schedule_cancel"
             ]

      assert again == cfg

      effects = Map.new(cfg["tools"], &{&1["name"], &1["effects"]})
      assert effects["schedule_create"] == ["state_write"]
      assert effects["schedule_cancel"] == ["state_write"]
      assert effects["schedule_list"] == ["read"]

      catalog = SuperPi.Tools.active_llm_tools() |> Enum.map(& &1["name"])
      refute Enum.any?(catalog, &String.starts_with?(&1, "schedule_"))
    end

    test "the trigger argument is offered only when webhooks are allowed" do
      props = fn opts ->
        opts |> Scheduler.tool_specs() |> hd() |> get_in(["parameters", "properties"])
      end

      refute Map.has_key?(props.([]), "trigger")
      assert Map.has_key?(props.(allow_webhooks: true), "trigger")
    end

    test "schedule_create, schedule_list and schedule_cancel" do
      conv = conversation!(%{"executionMode" => "accept-edits"})

      created =
        tool(
          "schedule_create",
          %{
            "prompt" => "Summarize my inbox",
            "cron" => "0 7 * * 1-5",
            "timezone" => "Europe/London",
            "name" => "briefing"
          },
          conv
        )

      refute created["is_error"]
      assert created["output"] =~ "Created schedule #"

      [schedule] = Sched.list(conv.id)
      assert schedule.cron == "0 7 * * 1-5"
      assert schedule.timezone == "Europe/London"
      assert schedule.mode == "fork"
      assert schedule.catch_up == false
      assert schedule.status == "active"
      assert schedule.harness == "super-pi-librarian"
      assert schedule.agent["executionMode"] == "accept-edits"
      assert DateTime.compare(schedule.next_fire_at, DateTime.utc_now()) == :gt

      listed = tool("schedule_list", %{}, conv)
      assert listed["output"] =~ "briefing"
      assert listed["output"] =~ "0 7 * * 1-5"
      assert [%{"id" => id}] = listed["structured_output"]["schedules"]
      assert id == schedule.id

      assert %{"is_error" => true} = tool("schedule_cancel", %{"id" => schedule.id + 100}, conv)
      refute tool("schedule_cancel", %{"id" => schedule.id}, conv)["is_error"]
      assert tool("schedule_list", %{}, conv)["output"] == "No schedules."
      assert reload(schedule).status == "cancelled"
    end

    test "a conversation cannot cancel another conversation's schedule" do
      a = conversation!()
      b = conversation!()
      schedule = create!(a)

      assert %{"is_error" => true} = tool("schedule_cancel", %{"id" => schedule.id}, b)
      assert reload(schedule).status == "active"
    end

    test "invalid input is reported, not raised" do
      conv = conversation!()

      assert %{"is_error" => true, "output" => out} =
               tool("schedule_create", %{"prompt" => "x", "cron" => "nonsense"}, conv)

      assert out =~ "expression"

      assert %{"is_error" => true} =
               tool(
                 "schedule_create",
                 %{"prompt" => "x", "cron" => "0 7 * * *", "timezone" => "Mars/Olympus"},
                 conv
               )

      assert %{"is_error" => true} =
               tool("schedule_create", %{"prompt" => "", "cron" => "0 7 * * *"}, conv)

      assert %{"is_error" => true} =
               tool(
                 "schedule_create",
                 %{"prompt" => "x", "cron" => "0 7 * * *", "mode" => "teleport"},
                 conv
               )

      assert %{"is_error" => true, "output" => interval} =
               tool("schedule_create", %{"prompt" => "x", "cron" => "* * * * *"}, conv)

      assert interval =~ "at least 5 minutes"
      assert Sched.list(conv.id) == []
    end

    test "a conversation has a limited number of schedules" do
      conv = conversation!()
      config = [max_per_conversation: 2]

      for _ <- 1..2,
          do:
            refute(
              tool("schedule_create", %{"prompt" => "x", "cron" => "0 7 * * *"}, conv, %{
                config: config
              })["is_error"]
            )

      assert %{"is_error" => true, "output" => out} =
               tool("schedule_create", %{"prompt" => "x", "cron" => "0 7 * * *"}, conv, %{
                 config: config
               })

      assert out =~ "limit 2"
    end

    test "webhook triggers are off unless the harness opts in" do
      conv = conversation!()

      assert %{"is_error" => true} =
               tool("schedule_create", %{"prompt" => "x", "trigger" => "webhook"}, conv)

      result =
        tool("schedule_create", %{"prompt" => "x", "trigger" => "webhook"}, conv, %{
          config: [allow_webhooks: true]
        })

      refute result["is_error"]
      assert "/v1/triggers/" <> token = result["structured_output"]["path"]

      # Only the hash is stored.
      [schedule] = Sched.list(conv.id)
      assert schedule.kind == "webhook"
      assert schedule.token_hash == Sched.hash_token(token)
      refute schedule.token_hash == token
      assert is_nil(schedule.next_fire_at)
    end

    test "other tools pass through" do
      assert :passed = Scheduler.wrap_tool("todo", %{}, fn _ -> :passed end, %{})
    end
  end

  describe "tick" do
    test "enqueues a run for the scheduled minute and moves next_fire_at forward" do
      conv = conversation!()
      schedule = create!(conv, %{cron: "*/10 * * * *"})
      due = minute(-1)
      set!(schedule, next_fire_at: due)

      assert Sched.tick(minute()) == 1

      assert [job] = run_jobs()
      assert job.args == %{"schedule_id" => schedule.id, "fire_at" => DateTime.to_iso8601(due)}

      moved = reload(schedule).next_fire_at
      assert DateTime.compare(moved, minute()) == :gt
      assert rem(moved.minute, 10) == 0
    end

    test "a second tick for the same minute inserts nothing" do
      conv = conversation!()
      schedule = create!(conv, %{cron: "*/10 * * * *"})
      set!(schedule, next_fire_at: minute(-1))

      assert Sched.tick(minute()) == 1
      assert Sched.tick(minute()) == 0
      assert length(run_jobs()) == 1
    end

    test "a stale copy of the row cannot fire twice: the next_fire_at guard and the unique job key" do
      conv = conversation!()
      schedule = create!(conv, %{cron: "*/10 * * * *"})
      due = minute(-1)
      set!(schedule, next_fire_at: due)

      # The unique key alone: the same fire inserted twice is one job.
      args = %{"schedule_id" => schedule.id, "fire_at" => DateTime.to_iso8601(due)}
      assert {:ok, %Oban.Job{conflict?: false}} = args |> ScheduleRunWorker.new() |> Oban.insert()
      assert {:ok, %Oban.Job{conflict?: true}} = args |> ScheduleRunWorker.new() |> Oban.insert()
      assert length(run_jobs()) == 1
    end

    test "the tick worker takes the minute from the job" do
      conv = conversation!()
      schedule = create!(conv, %{cron: "*/10 * * * *"})
      due = minute(-1)
      set!(schedule, next_fire_at: due)

      assert :ok =
               ScheduleTickWorker.perform(%Oban.Job{
                 scheduled_at: DateTime.add(minute(), 17, :second)
               })

      assert [%{args: %{"fire_at" => fire_at}}] = run_jobs()
      assert fire_at == DateTime.to_iso8601(due)
    end

    test "a schedule that is not due, paused or cancelled does not fire" do
      conv = conversation!()
      future = create!(conv)
      paused = create!(conv)
      cancelled = create!(conv)
      set!(paused, next_fire_at: minute(-1), status: "paused")
      set!(cancelled, next_fire_at: minute(-1), status: "cancelled")

      assert Sched.tick(minute()) == 0
      assert run_jobs() == []
      assert reload(future).status == "active"
    end

    test "without catch-up a fire that is too late is skipped; with catch-up it runs once" do
      conv = conversation!()
      late = create!(conv, %{cron: "*/10 * * * *"})
      catch_up = create!(conv, %{cron: "*/10 * * * *", catch_up: true})
      set!(late, next_fire_at: minute(-30))
      set!(catch_up, next_fire_at: minute(-30))

      assert Sched.tick(minute()) == 2

      assert [job] = run_jobs()
      assert job.args["schedule_id"] == catch_up.id
      # The missed minutes collapse into the one run, and both schedules move on.
      assert job.args["fire_at"] == DateTime.to_iso8601(minute(-30))

      for s <- [late, catch_up],
          do: assert(DateTime.compare(reload(s).next_fire_at, minute()) != :lt)
    end

    test "a schedule that cannot be computed pauses with a note" do
      conv = conversation!()
      schedule = create!(conv)
      set!(schedule, next_fire_at: minute(-1), timezone: "Mars/Olympus")

      Sched.tick(minute())

      assert reload(schedule).status == "paused"

      assert [%{"kind" => "schedule_paused"}] =
               Doc.snapshot("conversation", conv.id, "pi.inbox")["notes"]
    end
  end

  describe "run" do
    defp fire_args(schedule, fire_at),
      do: %{"schedule_id" => schedule.id, "fire_at" => DateTime.to_iso8601(fire_at)}

    test "the same fire twice makes one run task" do
      conv = conversation!()
      schedule = create!(conv)
      args = fire_args(schedule, minute(-1))

      assert {:ok, task_id} = Sched.run(args)
      assert is_integer(task_id)
      assert {:ok, :skipped} = Sched.run(args)

      assert [task] = all_run_tasks()
      assert task.id == task_id
      assert reload(schedule).last_fire_at == minute(-1)
    end

    test "an older fire than the claimed one is skipped, a newer one runs" do
      conv = conversation!()
      schedule = create!(conv, %{mode: "append"})

      assert {:ok, _} = Sched.run(fire_args(schedule, minute(-1)))
      assert {:ok, :skipped} = Sched.run(fire_args(schedule, minute(-5)))
      assert {:ok, id} = Sched.run(fire_args(schedule, minute(0)))
      assert is_integer(id)
      assert length(tasks(conv.id)) == 2
    end

    test "concurrent runs of the same fire make one task" do
      conv = conversation!()
      schedule = create!(conv, %{mode: "append"})
      args = fire_args(schedule, minute(-1))
      parent = self()

      results =
        1..4
        |> Enum.map(fn _ ->
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.allow(SuperPi.Repo.active_repo(), parent, self())
            Sched.run(args)
          end)
        end)
        |> Enum.map(&Task.await(&1, 15_000))

      assert Enum.count(results, &match?({:ok, id} when is_integer(id), &1)) == 1
      assert length(tasks(conv.id)) == 1
    end

    test "the worker runs the claim, and a cancelled or paused schedule is skipped" do
      conv = conversation!()
      active = create!(conv, %{mode: "append"})
      cancelled = create!(conv, %{mode: "append"})
      paused = create!(conv, %{mode: "append"})
      set!(cancelled, status: "cancelled")
      set!(paused, status: "paused")

      for s <- [active, cancelled, paused] do
        assert :ok =
                 ScheduleRunWorker.perform(%Oban.Job{
                   args: fire_args(s, minute(-1)),
                   attempt: 1,
                   max_attempts: 3
                 })
      end

      assert [task] = tasks(conv.id)
      assert task.input["schedule_id"] == active.id
    end

    test "the run task is background, limited to two restarts, and abandoned on restart without catch-up" do
      conv = conversation!()
      plain = create!(conv, %{mode: "append"})
      catching = create!(conv, %{mode: "append", catch_up: true})

      {:ok, a} = Sched.run(fire_args(plain, minute(-1)))
      {:ok, b} = Sched.run(fire_args(catching, minute(-1)))

      task_a = Repo.get!(TaskSchema, a)

      assert %{
               background: true,
               restart_limit: 2,
               abandon_on_restart: true,
               status: "pending",
               kind: "pi.generation"
             } = task_a

      assert %{background: true, restart_limit: 2, abandon_on_restart: false} =
               Repo.get!(TaskSchema, b)

      assert task_a.input["prompt"] == "do it"
      assert reload(plain).last_task_id == a
    end

    test "fork mode branches the owning conversation, keeps the parent clean and copies no schedule" do
      conv = conversation!(%{"executionMode" => "accept-edits"})
      schedule = create!(conv)

      {:ok, task_id} = Sched.run(fire_args(schedule, minute(-1)))
      task = Repo.get!(TaskSchema, task_id)

      refute task.conversation_id == conv.id
      child = Repo.get!(Conversation, task.conversation_id)
      assert child.parent_conversation_id == conv.id
      assert Doc.snapshot("conversation", child.id, "pi.agent")["executionMode"] == "accept-edits"
      assert tasks(conv.id) == []
      assert Sched.list(child.id) == []

      # The prompt is the newest entry of the branch, and the parent has no new entry.
      messages = SuperPi.Durable.Context.derive(child.id).messages
      assert inspect(List.last(messages)) =~ "do it"
      refute inspect(SuperPi.Durable.Context.derive(conv.id).messages) =~ "do it"
    end

    test "fork mode of a conversation without entries starts fresh" do
      conv = Storage.create_conversation!(agent: %{"model" => "m"})
      schedule = create!(conv)

      {:ok, task_id} = Sched.run(fire_args(schedule, minute(-1)))
      child = Repo.get!(Conversation, Repo.get!(TaskSchema, task_id).conversation_id)
      assert is_nil(child.parent_conversation_id)
      refute child.id == conv.id
    end

    test "fresh mode starts a new conversation from the stored agent snapshot" do
      conv = conversation!(%{"executionMode" => "accept-edits", "effort" => "low"})

      schedule =
        create!(conv, %{mode: "fresh", agent: %{"model" => "snapshot", "effort" => "high"}})

      # `create!` passes the snapshot; the tool captures it from `pi.agent`.
      {:ok, task_id} = Sched.run(fire_args(schedule, minute(-1)))
      child = Repo.get!(Conversation, Repo.get!(TaskSchema, task_id).conversation_id)

      assert is_nil(child.parent_conversation_id)

      assert %{"model" => "snapshot", "effort" => "high"} =
               Doc.snapshot("conversation", child.id, "pi.agent")
    end

    test "append mode adds the turn to the owning conversation" do
      conv = conversation!()
      schedule = create!(conv, %{mode: "append"})
      {:ok, task_id} = Sched.run(fire_args(schedule, minute(-1)))

      assert Repo.get!(TaskSchema, task_id).conversation_id == conv.id
      assert inspect(SuperPi.Durable.Context.derive(conv.id).messages) =~ "do it"
    end

    test "a forked run executes its turn to the end" do
      Application.put_env(:super_pi, :scheduler_autostart, true)
      conv = conversation!()
      schedule = create!(conv)

      {:ok, task_id} = Sched.run(fire_args(schedule, minute(-1)))
      eventually(fn -> Repo.get!(TaskSchema, task_id).status == "completed" end)

      child_id = Repo.get!(TaskSchema, task_id).conversation_id
      assert inspect(SuperPi.Durable.Context.derive(child_id).messages) =~ "Echo: do it"
    end

    test "an append run starts on a machine that is idle already" do
      Application.put_env(:super_pi, :scheduler_autostart, true)
      conv = conversation!()
      {:ok, pid} = SuperPi.Conversation.Locator.ensure_started(conv.id, extensions: [])
      eventually(fn -> elem(SuperPi.Conversation.Machine.get_state(pid), 0) == :idle end)

      schedule = create!(conv, %{mode: "append"})
      {:ok, task_id} = Sched.run(fire_args(schedule, minute(-1)))
      eventually(fn -> Repo.get!(TaskSchema, task_id).status == "completed" end)
    end

    test "a run job that keeps failing counts against the schedule after its last attempt" do
      conv = conversation!()
      schedule = create!(conv, %{mode: "append"})
      # An unreadable fire time makes the claim raise.
      args = %{"schedule_id" => schedule.id, "fire_at" => "not a time"}

      assert {:error, _} =
               ScheduleRunWorker.perform(%Oban.Job{args: args, attempt: 1, max_attempts: 3})

      assert reload(schedule).consecutive_failures == 0

      assert {:error, _} =
               ScheduleRunWorker.perform(%Oban.Job{args: args, attempt: 3, max_attempts: 3})

      assert reload(schedule).consecutive_failures == 1
    end
  end

  describe "failures" do
    test "three failed runs in a row pause the schedule and leave a note in pi.inbox" do
      conv = conversation!()
      schedule = create!(conv)

      for n <- 1..3 do
        fail_task!(conv.id, schedule, "provider down #{n}")
        Sched.settle_runs()
        assert reload(schedule).consecutive_failures == n
        assert reload(schedule).status == if(n < 3, do: "active", else: "paused")
      end

      paused = reload(schedule)
      assert paused.last_error =~ "provider down 3"
      assert is_nil(paused.last_task_id)

      inbox = Doc.snapshot("conversation", conv.id, "pi.inbox")
      assert inbox["queued"] == []

      assert [%{"kind" => "schedule_paused", "schedule_id" => id, "text" => text}] =
               inbox["notes"]

      assert id == schedule.id
      assert text =~ "paused"

      # A paused schedule does not fire.
      set!(schedule, next_fire_at: minute(-1))
      assert Sched.tick(minute()) == 0
    end

    test "a completed run resets the count; a cancelled run changes nothing" do
      conv = conversation!()
      schedule = create!(conv)

      fail_task!(conv.id, schedule)
      Sched.settle_runs()
      assert reload(schedule).consecutive_failures == 1

      {:ok, cancelled} =
        TaskEngine.create_task(conv.id, "pi.generation", %{"schedule_id" => schedule.id})

      {:ok, _} = TaskEngine.start_task(cancelled.id)
      {:ok, _} = TaskEngine.cancel_task(cancelled.id)
      set!(schedule, last_task_id: cancelled.id)
      Sched.settle_runs()
      assert reload(schedule).consecutive_failures == 1
      assert is_nil(reload(schedule).last_task_id)

      {:ok, ok_task} =
        TaskEngine.create_task(conv.id, "pi.generation", %{"schedule_id" => schedule.id})

      {:ok, _} = TaskEngine.start_task(ok_task.id)
      {:ok, _} = TaskEngine.complete_task(ok_task.id, %{})
      set!(schedule, last_task_id: ok_task.id)
      Sched.settle_runs()
      assert reload(schedule).consecutive_failures == 0
    end

    test "a run that is still going is not accounted yet" do
      conv = conversation!()
      schedule = create!(conv, %{mode: "append"})
      {:ok, task_id} = Sched.run(fire_args(schedule, minute(-1)))
      Sched.settle_runs()
      assert reload(schedule).last_task_id == task_id
    end

    test "a failure is counted once even if two ticks account at the same time" do
      conv = conversation!()
      schedule = create!(conv)
      fail_task!(conv.id, schedule)

      Sched.settle_runs()
      Sched.settle_runs()
      assert reload(schedule).consecutive_failures == 1
    end

    test "resume clears the failures and computes the next fire" do
      conv = conversation!()
      schedule = create!(conv)
      set!(schedule, status: "paused", consecutive_failures: 3, next_fire_at: minute(-100))

      assert :ok = Sched.resume(schedule.id)
      resumed = reload(schedule)
      assert resumed.status == "active"
      assert resumed.consecutive_failures == 0
      assert DateTime.compare(resumed.next_fire_at, DateTime.utc_now()) == :gt
      assert {:error, :not_paused} = Sched.resume(schedule.id)
    end
  end

  describe "loop guard" do
    defp scheduled_task!(conv) do
      schedule = create!(conv)
      {:ok, id} = Sched.run(fire_args(schedule, minute(-1)))
      Repo.get!(TaskSchema, id)
    end

    test "schedule_create is blocked inside a scheduled run" do
      conv = conversation!()
      run = scheduled_task!(conv)

      result =
        tool(
          "schedule_create",
          %{"prompt" => "x", "cron" => "0 7 * * *"},
          %{id: run.conversation_id},
          %{active_task_id: run.id}
        )

      assert %{"is_error" => true, "output" => out} = result
      assert out =~ "scheduled run"
      assert Sched.list(run.conversation_id) == []
    end

    test "it is allowed in an ordinary turn, and in a scheduled run when allow_nested is set" do
      conv = conversation!()
      run = scheduled_task!(conv)
      {:ok, plain} = TaskEngine.create_task(conv.id, "pi.generation")

      args = %{"prompt" => "x", "cron" => "0 7 * * *"}
      refute tool("schedule_create", args, conv, %{active_task_id: plain.id})["is_error"]

      child = %{id: run.conversation_id}

      refute tool("schedule_create", args, child, %{
               active_task_id: run.id,
               config: [allow_nested: true]
             })["is_error"]
    end

    test "a subagent child of a scheduled run is blocked too" do
      conv = conversation!()
      run = scheduled_task!(conv)

      {:ok, sub} =
        TaskEngine.create_task(run.conversation_id, "pi.subagent", %{}, owner_task_id: nil)

      {:ok, _} = TaskEngine.start_task(run.id)

      child_conv =
        Storage.create_conversation!(owner_kind: "task", owner_task_id: sub.id, agent: %{})

      {:ok, child_task} = TaskEngine.create_task(child_conv.id, "pi.generation")

      # child task -> its conversation is owned by `sub` -> `sub` is a plain task of the scheduled run's
      # conversation, so the chain ends there unless `sub` descends from the run.
      refute Sched.scheduled_run?(child_task.id)

      {:ok, sub_of_run} =
        TaskEngine.create_task(run.conversation_id, "pi.subagent", %{}, owner_task_id: run.id)

      child_conv2 =
        Storage.create_conversation!(owner_kind: "task", owner_task_id: sub_of_run.id, agent: %{})

      {:ok, child_task2} = TaskEngine.create_task(child_conv2.id, "pi.generation")
      assert Sched.scheduled_run?(child_task2.id)
    end

    test "no task is not a scheduled run" do
      refute Sched.scheduled_run?(nil)
      refute Sched.scheduled_run?(999_999)
    end
  end

  describe "registration" do
    test "the plugin resolves by id and is listed" do
      assert SuperPi.Plugins.resolve("scheduler") == Scheduler
      assert Scheduler in SuperPi.Plugins.list()

      assert Scheduler in Enum.map(SuperPi.Harness.Librarian.extensions(), fn
               {m, _} -> m
               m -> m
             end)
    end
  end
end
