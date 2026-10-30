defmodule SuperPi.ClusterTest do
  @moduledoc """
  A real cluster: three Erlang nodes (started with `:peer`) run the whole application against one
  PostgreSQL. The test node is only a controller.

      createdb super_pi_test
      SUPER_PI_STORAGE_BACKEND=postgres DATABASE_URL=ecto://user@host/super_pi_test \\
        mix test --only cluster test/super_pi/cluster_test.exs

  The data is committed for real and removed at the end.
  """
  use ExUnit.Case, async: false

  alias SuperPi.ClusterSupport, as: Support

  @moduletag :cluster
  @moduletag timeout: 180_000

  if Application.compile_env(:super_pi, :storage_backend, :sqlite) != :postgres do
    @moduletag skip: "needs SUPER_PI_STORAGE_BACKEND=postgres"
  end

  setup_all do
    Support.ensure_distributed()
    Support.become_controller()
    peers = Support.start_peers(3, mock_llm: true)
    on_exit(fn -> Support.stop_peers(peers) end)

    wait_until(
      fn -> Enum.all?(peers, &(length(registry_members(&1.node)) == 3)) end,
      30_000,
      "Horde members to join"
    )

    # Owned by the setup_all process, which lives for the whole module, so on_exit can read it.
    created = :ets.new(:cluster_created, [:public, :bag])
    %{peers: peers, created: created}
  end

  setup %{peers: [a | _], created: created} do
    on_exit(fn ->
      ids = created |> :ets.tab2list() |> Enum.map(&elem(&1, 1))
      :ets.delete_all_objects(created)
      if ids != [], do: :erpc.call(a.node, Support, :cleanup, [ids])
    end)

    :ok
  end

  defp call(%{node: node}, mod, fun, args), do: :erpc.call(node, mod, fun, args, 60_000)

  defp registry_members(node),
    do: :erpc.call(node, SuperPi.Cluster, :status, [])[:registry_members] || []

  defp conversation(peer, created, agent \\ %{"model" => "m"}) do
    id = call(peer, Support, :create_conversation, [agent])
    :ets.insert(created, {:conv, id})
    id
  end

  defp owner_of(peer, id), do: call(peer, SuperPi.Conversation.Locator, :whereis, [id])

  defp ensure(peer, id),
    do: call(peer, SuperPi.Conversation.Locator, :ensure_started, [id, [extensions: []]])

  # Stops a machine through the supervisor on its own node, by pid. (Looking it up by conversation
  # right after it started can miss: the registry replica on another node is not up to date yet.)
  defp stop_machine(pid), do: :erpc.call(node(pid), Support, :terminate_local, [pid])

  # Horde chooses the node. Start the machine until it lands on `host_node`, so a test can rely on
  # where it runs. Placement is stable for a fixed set of members, so this normally takes one try.
  defp ensure_on(peer, id, host_node, tries \\ 10) do
    {:ok, pid} = ensure(peer, id)

    cond do
      node(pid) == host_node ->
        pid

      tries == 0 ->
        flunk("the machine did not start on #{host_node}; it is on #{node(pid)}")

      true ->
        stop_machine(pid)
        wait_until(fn -> owner_of(peer, id) == nil end, 10_000, "the machine to stop")
        ensure_on(peer, id, host_node, tries - 1)
    end
  end

  defp wait_until(fun, timeout, what) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      cond do
        fun.() -> :ok
        System.monotonic_time(:millisecond) > deadline -> flunk("timed out waiting for #{what}")
        true -> Process.sleep(100) && nil
      end
    end)
    |> Enum.find(&(&1 == :ok))
  end

  test "the nodes see each other, and Horde has all three as members", %{peers: peers} do
    for peer <- peers do
      status = call(peer, SuperPi.Cluster, :status, [])
      assert length(status.connected_nodes) == 2
      assert Enum.sort(status.registry_members) == Enum.sort(Enum.map(peers, & &1.node))
      assert status.db_adapter == SuperPi.Repo.Postgres
    end
  end

  test "a conversation has one machine in the cluster, whichever node asks", %{
    peers: [a, b, c],
    created: created
  } do
    id = conversation(a, created)

    {:ok, pid_a} = ensure(a, id)
    {:ok, pid_b} = ensure(b, id)
    {:ok, pid_c} = ensure(c, id)

    assert pid_a == pid_b and pid_b == pid_c
    wait_until(fn -> owner_of(c, id) == pid_a end, 10_000, "the registry to replicate")
  end

  test "concurrent starts from every node end in one machine", %{peers: peers, created: created} do
    id = conversation(hd(peers), created)

    pids =
      peers
      |> Task.async_stream(fn peer -> ensure(peer, id) end, timeout: 60_000)
      |> Enum.map(fn {:ok, {:ok, pid}} -> pid end)
      |> Enum.uniq()

    assert length(pids) == 1
  end

  test "a turn submitted from another node runs on the owner and is stored", %{
    peers: [a, b | _],
    created: created
  } do
    id = conversation(a, created)
    {:ok, pid} = ensure(a, id)
    other = Enum.find([a, b], &(&1.node != node(pid)))

    # `other` calls the machine through its pid, across nodes.
    assert {:ok, msg} =
             call(other, SuperPi.Conversation.Machine, :submit, [
               pid,
               "hello cluster",
               [timeout: 30_000]
             ])

    assert inspect(msg) =~ "Echo: hello cluster"

    assert Enum.any?(call(a, Support, :messages, [id]), &(inspect(&1) =~ "Echo: hello cluster"))
  end

  test "a document written on one node is seen on another within a second", %{
    peers: [a, b | _],
    created: created
  } do
    id = conversation(a, created, %{"model" => "before"})

    # Warm b's cache.
    assert call(b, SuperPi.Durable.Doc, :snapshot, ["conversation", id, "pi.agent"])["model"] ==
             "before"

    call(a, SuperPi.Durable.Storage, :configure_agent!, [id, %{model: "after"}])

    # The TTL is 5 s on a cluster, so only the invalidation message can make this fast.
    wait_until(
      fn ->
        call(b, SuperPi.Durable.Doc, :snapshot, ["conversation", id, "pi.agent"])["model"] ==
          "after"
      end,
      1_000,
      "b to see the new value"
    )
  end

  test "concurrent usage updates from two nodes add up", %{peers: [a, b | _], created: created} do
    id = conversation(a, created)

    for peer <- [a, b], _ <- 1..10 do
      Task.async(fn -> call(peer, Support, :add_usage, [id]) end)
    end
    |> Enum.each(&Task.await(&1, 60_000))

    assert call(a, Support, :doc, [id, "pi.usage"])["inputTokens"] == 20
  end

  test "a question asked on one node is answered from another", %{
    peers: [a, b, c],
    created: created
  } do
    id = conversation(a, created)

    call(b, Support, :start_responder, [id, self()])
    assert_receive {:responder_ready, _}, 10_000

    wait_until(
      fn -> call(a, SuperPi.UI.Broker, :responder?, [id]) end,
      10_000,
      "the responder group to replicate"
    )

    call(a, Support, :start_asker, [id, self()])
    assert_receive {:ui_request, responder_node, %{"request_id" => request_id}}, 10_000
    assert responder_node == b.node

    # A third node answers.
    assert :ok = call(c, SuperPi.UI.Broker, :respond, [request_id, "yes"])
    assert_receive {:answer, {:ok, "yes"}}, 10_000
  end

  test "a question with no responder anywhere fails at once", %{peers: [a | _], created: created} do
    id = conversation(a, created)
    call(a, Support, :start_asker, [id, self()])
    assert_receive {:answer, {:error, :no_interactive_client}}, 5_000
  end

  test "recovery leaves a task that another live node runs", %{peers: [a, b, c], created: created} do
    id = conversation(a, created)

    # Find where the machine for this conversation lands, then use another live node as the task owner.
    {:ok, probe} = ensure(a, id)
    host = Enum.find([a, b, c], &(&1.node == node(probe)))
    stop_machine(probe)
    wait_until(fn -> owner_of(a, id) == nil end, 10_000, "the probe machine to stop")

    other = Enum.find([a, b, c], &(&1.node != host.node))
    task = call(a, Support, :create_running_task, [id, other.node])

    # The machine starts on `host` again. The task belongs to live node `other`: it is not reset or resumed.
    ensure_on(a, id, host.node)
    Process.sleep(700)

    after_start = call(a, Support, :get_task, [task.id])
    assert after_start.status == "running"
    assert after_start.attempt == 0
  end

  test "recovery resets and resumes a task that this node ran before", %{
    peers: [a, b, c],
    created: created
  } do
    id = conversation(a, created)
    {:ok, probe} = ensure(a, id)
    host = Enum.find([a, b, c], &(&1.node == node(probe)))
    stop_machine(probe)
    wait_until(fn -> owner_of(a, id) == nil end, 10_000, "the probe machine to stop")

    # A turn that this node had started: user message stored, task running, no machine (it crashed).
    call(host, SuperPi.Durable.Storage, :append_entry!, [
      id,
      "pi.message",
      %{"role" => "user", "content" => [%{"type" => "text", "text" => "pick this up"}]}
    ])

    task = call(a, Support, :create_running_task, [id, host.node])

    ensure_on(a, id, host.node)

    wait_until(
      fn -> call(a, Support, :get_task, [task.id]).status == "completed" end,
      20_000,
      "the resumed turn to complete"
    )

    assert call(a, Support, :get_task, [task.id]).attempt == 1
  end

  describe "node failure" do
    test "the conversation resumes on a surviving node and the turn completes", %{
      created: created
    } do
      # This test kills a node, so it uses its own peers (slow replies make the turn interruptible).
      peers = Support.start_peers(3, mock_llm: true, mock_llm_delay_ms: 4_000)
      on_exit(fn -> Support.stop_peers(peers) end)

      wait_until(
        fn -> Enum.all?(peers, &(length(registry_members(&1.node)) == 3)) end,
        30_000,
        "Horde members to join"
      )

      [a | _] = peers
      id = conversation(a, created)

      call(a, Support, :submit_async, [id, "survive this", self()])
      pid = wait_for_owner(a, id)
      victim = Enum.find(peers, &(&1.node == node(pid)))
      survivors = peers -- [victim]

      # Wait until the turn is running and a survivor knows the machine. Horde replicates its child
      # list on an interval. A node that dies inside that interval takes the unreplicated child
      # with it, and nothing restarts it until the next request calls `ensure_started`.
      wait_until(fn -> running_task?(hd(survivors), id) end, 20_000, "the turn to start")

      wait_until(
        fn -> supervised_on?(hd(survivors), pid) end,
        20_000,
        "a survivor to learn the machine"
      )

      :erpc.cast(victim.node, :erlang, :halt, [1])

      # Horde usually restarts the machine on a survivor within seconds. In some runs it does not
      # (observed when the first node of the Horde cluster dies: the survivors drop the child and
      # start nothing). The next request then starts the machine, which is what `ensure_started`
      # does here, and the recovery resumes the turn. Either path must complete the turn.
      restarted? =
        try do
          wait_until(
            fn ->
              case owner_of(hd(survivors), id) do
                new when is_pid(new) -> node(new) != victim.node
                _ -> false
              end
            end,
            20_000,
            "the machine to restart on a surviving node"
          )

          true
        rescue
          ExUnit.AssertionError -> false
        end

      unless restarted?, do: {:ok, _} = ensure(hd(survivors), id)

      wait_until(
        fn -> task_status(hd(survivors), id) == "completed" end,
        60_000,
        "the resumed turn to complete"
      )

      assert Enum.any?(
               call(hd(survivors), Support, :messages, [id]),
               &(inspect(&1) =~ "Echo: survive this")
             )
    end

    test "a draining node refuses new turns, finishes the running one, and hands over", %{
      created: created
    } do
      peers = Support.start_peers(2, mock_llm: true, mock_llm_delay_ms: 1_500)
      on_exit(fn -> Support.stop_peers(peers) end)

      wait_until(
        fn -> Enum.all?(peers, &(length(registry_members(&1.node)) == 2)) end,
        30_000,
        "Horde members to join"
      )

      [a | _] = peers
      id = conversation(a, created)
      call(a, Support, :submit_async, [id, "finish me", self()])
      pid = wait_for_owner(a, id)
      owner = Enum.find(peers, &(&1.node == node(pid)))
      wait_until(fn -> running_task?(owner, id) end, 20_000, "the turn to start")

      started = System.monotonic_time(:millisecond)
      assert :drained = call(owner, SuperPi.Drain, :drain, [20_000])

      assert System.monotonic_time(:millisecond) - started >= 500,
             "drain returned before the turn finished"

      assert_receive {:turn, {:ok, _}}, 5_000
      refute call(owner, SuperPi.Drain, :accepting?, [])
      assert call(owner, SuperPi.Cluster, :status, [])[:accepting?] == false
    end
  end

  describe "scheduler" do
    test "a fire runs once with several peers up, and the run survives its node dying", %{
      created: created
    } do
      # The run is a turn that takes a few seconds, so a node can be killed in the middle of it.
      peers = Support.start_peers(3, mock_llm: true, mock_llm_delay_ms: 4_000)
      on_exit(fn -> Support.stop_peers(peers) end)

      wait_until(
        fn -> Enum.all?(peers, &(length(registry_members(&1.node)) == 3)) end,
        30_000,
        "Horde members to join"
      )

      [a, b | _] = peers
      id = conversation(a, created)

      attrs = %{
        conversation_id: id,
        prompt: "morning briefing",
        cron: "0 7 * * *",
        mode: "append",
        catch_up: true
      }

      {:ok, schedule, nil} = call(a, SuperPi.Schedule, :create, [attrs])
      fire = %{"schedule_id" => schedule.id, "fire_at" => "2026-10-30T07:00:00Z"}

      # A duplicated job: two peers run the same fire at once. The conditional claim lets one through.
      results =
        [a, b]
        |> Task.async_stream(fn peer -> call(peer, SuperPi.Schedule, :run, [fire]) end,
          timeout: 60_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &match?({:ok, task_id} when is_integer(task_id), &1)) == 1
      assert {:ok, :skipped} in results
      assert call(a, Support, :generation_count, [id]) == 1

      pid = wait_for_owner(a, id)
      victim = Enum.find(peers, &(&1.node == node(pid)))
      survivors = peers -- [victim]
      wait_until(fn -> running_task?(hd(survivors), id) end, 20_000, "the run to start")

      wait_until(
        fn -> supervised_on?(hd(survivors), pid) end,
        20_000,
        "a survivor to learn the machine"
      )

      :erpc.cast(victim.node, :erlang, :halt, [1])

      # As in the node failure test: Horde restarts the machine, or the next request does.
      restarted? =
        try do
          wait_until(
            fn ->
              case owner_of(hd(survivors), id) do
                new when is_pid(new) -> node(new) != victim.node
                _ -> false
              end
            end,
            20_000,
            "the machine to restart on a surviving node"
          )

          true
        rescue
          ExUnit.AssertionError -> false
        end

      unless restarted?, do: {:ok, _} = ensure(hd(survivors), id)

      wait_until(
        fn -> task_status(hd(survivors), id) == "completed" end,
        60_000,
        "the resumed run to complete"
      )

      assert Enum.any?(
               call(hd(survivors), Support, :messages, [id]),
               &(inspect(&1) =~ "Echo: morning briefing")
             )

      # The same fire again, from a survivor, still makes no second run.
      assert {:ok, :skipped} = call(hd(survivors), SuperPi.Schedule, :run, [fire])
      assert call(hd(survivors), Support, :generation_count, [id]) == 1
    end
  end

  describe "subagents" do
    # A child turn that outlives a node. `kill: :machine` kills the node that hosts the child's
    # machine while the job's node lives (the job starts the machine again and waits). `kill: :job`
    # kills the node that runs the job, which hosts the machine too (Horde restarts the machine, and
    # the machine settles the task itself).
    for kill <- [:machine, :job] do
      @kill kill
      test "a child survives its node being killed (#{kill})", %{created: created} do
        peers = Support.start_peers(3, mock_llm: true, mock_llm_delay_ms: 4_000)
        on_exit(fn -> Support.stop_peers(peers) end)

        wait_until(
          fn -> Enum.all?(peers, &(length(registry_members(&1.node)) == 3)) end,
          30_000,
          "Horde members to join"
        )

        [a | _] = peers
        {parent_id, parent_task_id} = call(a, Support, :create_parent_turn, [])
        :ets.insert(created, {:conv, parent_id})

        res =
          call(a, Support, :delegate, [
            parent_id,
            parent_task_id,
            %{"role" => "scout", "prompt" => "survive this", "timeout_ms" => 100_000}
          ])

        assert [%{"task_id" => sub_task_id, "child_conversation_id" => child_id}] =
                 res["structured_output"]["subagents"]

        :ets.insert(created, {:conv, child_id})
        assert call(a, Support, :get_task, [parent_task_id]).status == "waiting"

        # Horde places the machine; the job runs on that node (`:job`) or on another one (`:machine`).
        {:ok, probe} = ensure(a, child_id)
        host = Enum.find(peers, &(&1.node == node(probe)))
        runner = if @kill == :job, do: host, else: Enum.find(peers, &(&1.node != host.node))
        :erpc.cast(runner.node, Support, :run_subagent_jobs, [])

        wait_until(
          fn -> call(a, Support, :generation_status, [child_id]) == "running" end,
          20_000,
          "the child's turn to start"
        )

        pid = owner_of(a, child_id)
        survivors = peers -- [host]

        wait_until(
          fn -> supervised_on?(hd(survivors), pid) end,
          20_000,
          "a survivor to learn the machine"
        )

        :erpc.cast(host.node, :erlang, :halt, [1])

        # Horde may not restart the machine (see the node failure test). The next request does.
        restarted? =
          try do
            wait_until(
              fn ->
                match?(
                  new when is_pid(new) and node(new) != host.node,
                  owner_of(hd(survivors), child_id)
                )
              end,
              20_000,
              "the machine to restart"
            )

            true
          rescue
            ExUnit.AssertionError -> false
          end

        # In the `:machine` case the job's node is alive and starts the machine itself.
        unless restarted? or @kill == :machine do
          {:ok, _} =
            call(hd(survivors), SuperPi.Conversation.Locator, :ensure_started, [
              child_id,
              SuperPi.Workers.SubagentWorker.machine_opts("scout")
            ])
        end

        wait_until(
          fn -> call(hd(survivors), Support, :get_task, [sub_task_id]).status == "completed" end,
          60_000,
          "the child to complete"
        )

        assert call(hd(survivors), Support, :get_task, [sub_task_id]).result["summary"] =~
                 "survive this"

        # The child's end woke the parent.
        assert call(hd(survivors), Support, :get_task, [parent_task_id]).status == "pending"
      end
    end
  end

  defp wait_for_owner(peer, id) do
    wait_until(fn -> is_pid(owner_of(peer, id)) end, 20_000, "a machine for the conversation")
    owner_of(peer, id)
  end

  defp supervised_on?(peer, pid) do
    children =
      :erpc.call(peer.node, Horde.DynamicSupervisor, :which_children, [SuperPi.MachineSupervisor])

    Enum.any?(children, fn {_id, child, _type, _modules} -> child == pid end)
  end

  defp running_task?(peer, id), do: task_status(peer, id) == "running"
  defp task_status(peer, id), do: call(peer, Support, :generation_status, [id])
end
