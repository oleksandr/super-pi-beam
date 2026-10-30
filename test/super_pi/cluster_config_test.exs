defmodule SuperPi.ClusterConfigTest do
  @moduledoc "Cluster settings, drain and single-node behavior. The multi-node tests are in cluster_test.exs."
  use SuperPi.DataCase, async: false
  import Plug.Test
  import Plug.Conn

  alias SuperPi.Cluster, as: SpCluster
  alias SuperPi.Drain
  alias SuperPi.Conversation.{Locator, Machine}
  alias SuperPi.Gateway.Router
  alias SuperPi.RPC.Server, as: RPC
  alias SuperPi.TestSupport.Faults

  @vars ~w(SUPER_PI_STORAGE_BACKEND DATABASE_URL SUPER_PI_CLUSTER_STRATEGY SUPER_PI_CLUSTER_HOSTS SUPER_PI_CLUSTER_DNS_QUERY
           SUPER_PI_CLUSTER_NODE_BASENAME SUPER_PI_CLUSTER_K8S_SERVICE SUPER_PI_CLUSTER_POLL_MS
           SUPER_PI_CLUSTER_GOSSIP_SECRET SUPER_PI_CLUSTER_GOSSIP_PORT)

  setup do
    saved = Enum.map(@vars, &{&1, System.get_env(&1)})
    Enum.each(@vars, &System.delete_env/1)

    on_exit(fn ->
      Drain.resume()

      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)
  end

  defp read(vars) do
    Enum.each(vars, fn {k, v} -> System.put_env(k, v) end)
    Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)[:super_pi][:cluster]
  end

  @pg %{"SUPER_PI_STORAGE_BACKEND" => "postgres", "DATABASE_URL" => "ecto://u:p@db/x"}

  describe "runtime.exs" do
    test "clustering is off by default" do
      assert [strategy: :none, topologies: []] = read(%{})
    end

    test "epmd takes a host list" do
      cfg = read(Map.merge(@pg, %{"SUPER_PI_CLUSTER_STRATEGY" => "epmd", "SUPER_PI_CLUSTER_HOSTS" => "super_pi@10.0.0.1, super_pi@10.0.0.2"}))
      assert [super_pi: [strategy: :"Elixir.Cluster.Strategy.Epmd", config: [hosts: hosts]]] = cfg[:topologies]
      assert hosts == [:"super_pi@10.0.0.1", :"super_pi@10.0.0.2"]
    end

    test "dnspoll takes a query, a base name and an interval" do
      cfg =
        read(Map.merge(@pg, %{"SUPER_PI_CLUSTER_STRATEGY" => "dnspoll", "SUPER_PI_CLUSTER_DNS_QUERY" => "sp.internal", "SUPER_PI_CLUSTER_POLL_MS" => "2000"}))

      assert [super_pi: [strategy: :"Elixir.Cluster.Strategy.DNSPoll", config: config]] = cfg[:topologies]
      assert config[:query] == "sp.internal"
      assert config[:node_basename] == "super_pi"
      assert config[:polling_interval] == 2000
    end

    test "kubernetes_dns takes the headless service name" do
      cfg = read(Map.merge(@pg, %{"SUPER_PI_CLUSTER_STRATEGY" => "kubernetes_dns", "SUPER_PI_CLUSTER_K8S_SERVICE" => "super-pi-headless", "SUPER_PI_CLUSTER_NODE_BASENAME" => "sp"}))
      assert [super_pi: [strategy: :"Elixir.Cluster.Strategy.Kubernetes.DNS", config: config]] = cfg[:topologies]
      assert config[:service] == "super-pi-headless"
      assert config[:application_name] == "sp"
    end

    test "gossip needs a secret" do
      cfg = read(Map.merge(@pg, %{"SUPER_PI_CLUSTER_STRATEGY" => "gossip", "SUPER_PI_CLUSTER_GOSSIP_SECRET" => "s3cret"}))
      assert [super_pi: [strategy: :"Elixir.Cluster.Strategy.Gossip", config: config]] = cfg[:topologies]
      assert config[:secret] == "s3cret"
      assert config[:port] == 45892
    end

    test "a strategy without its required variable is an error" do
      for {strategy, var} <- [{"epmd", "SUPER_PI_CLUSTER_HOSTS"}, {"dnspoll", "SUPER_PI_CLUSTER_DNS_QUERY"}, {"kubernetes_dns", "SUPER_PI_CLUSTER_K8S_SERVICE"}, {"gossip", "SUPER_PI_CLUSTER_GOSSIP_SECRET"}] do
        assert_raise RuntimeError, ~r/#{var}/, fn -> read(Map.merge(@pg, %{"SUPER_PI_CLUSTER_STRATEGY" => strategy})) end
      end
    end

    test "an unknown strategy is an error" do
      assert_raise RuntimeError, ~r/must be none, epmd/, fn -> read(Map.merge(@pg, %{"SUPER_PI_CLUSTER_STRATEGY" => "carrier-pigeon"})) end
    end

    test "a cluster over SQLite is refused" do
      assert_raise RuntimeError, ~r/needs SUPER_PI_STORAGE_BACKEND=postgres/, fn ->
        read(%{"SUPER_PI_CLUSTER_STRATEGY" => "epmd", "SUPER_PI_CLUSTER_HOSTS" => "a@b"})
      end
    end
  end

  describe "SuperPi.Cluster" do
    test "validate! refuses a cluster over SQLite, and accepts none" do
      assert :ok = SpCluster.validate!()

      Application.put_env(:super_pi, :cluster, strategy: :epmd, topologies: [super_pi: [strategy: :"Elixir.Cluster.Strategy.Epmd", config: [hosts: []]]])
      on_exit(fn -> Application.delete_env(:super_pi, :cluster) end)

      assert SpCluster.enabled?()
      if SuperPi.Repo.active_repo() == SuperPi.Repo.SQLite, do: assert_raise(ArgumentError, ~r/needs PostgreSQL/, &SpCluster.validate!/0)
    end

    test "children are empty without a strategy" do
      assert SpCluster.children() == []
    end

    test "status on one node" do
      conv = SuperPi.Durable.Storage.create_conversation!()
      {:ok, _} = Locator.ensure_started(conv.id, extensions: [], llm_responder: fn _, _ -> {:ok, Faults.text_msg("ok")} end)

      status = SpCluster.status()
      assert status.self == node()
      assert status.strategy == :none
      assert status.connected_nodes == []
      assert status.cluster_ready? == false
      assert status.accepting? == true
      assert status.machine_count >= 1
      assert status.machines_per_node[node()] >= 1
      assert node() in status.registry_members
      assert node() in status.supervisor_members
    end
  end

  describe "Locator" do
    defp responder, do: fn _p, _c -> {:ok, Faults.text_msg("ok")} end

    test "one machine per conversation, the same pid every time" do
      conv = SuperPi.Durable.Storage.create_conversation!()
      {:ok, pid} = Locator.ensure_started(conv.id, extensions: [], llm_responder: responder())
      assert {:ok, ^pid} = Locator.ensure_started(conv.id, extensions: [])
      assert Locator.whereis(conv.id) == pid
    end

    test "supervision :local keeps the machine under the local supervisor" do
      conv = SuperPi.Durable.Storage.create_conversation!()
      {:ok, pid} = Locator.ensure_started(conv.id, [extensions: [], llm_responder: responder()], supervision: :local)

      assert pid in Enum.map(DynamicSupervisor.which_children(SuperPi.LocalMachineSupervisor), &elem(&1, 1))
      assert {:ok, _} = Machine.submit(pid, "hi", timeout: 10_000)
    end

    test "a machine that stops normally is not restarted" do
      conv = SuperPi.Durable.Storage.create_conversation!()
      {:ok, pid} = Locator.ensure_started(conv.id, extensions: [], llm_responder: responder())
      :gen_statem.stop(pid)
      assert :ok = Locator.await_gone(conv.id)
      Process.sleep(200)
      assert Locator.whereis(conv.id) == nil
    end

    test "a machine that is killed under Horde is restarted and recovers" do
      conv = SuperPi.Durable.Storage.create_conversation!()
      {:ok, pid} = Locator.ensure_started(conv.id, extensions: [], llm_responder: responder())
      # Wait until it is idle. Killing a process in the middle of a database call would break the
      # shared sandbox connection, which is a test artifact, not what a node failure does.
      assert {:idle, _} = :gen_statem.call(pid, :get_state)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Process.exit(pid, :kill)

          Enum.find_value(1..100, fn _ ->
            case Locator.whereis(conv.id) do
              new when is_pid(new) and new != pid -> new
              _ -> Process.sleep(50) && nil
            end
          end)
          |> then(&Process.put(:restarted, &1))
        end)

      restarted = Process.get(:restarted)
      assert is_pid(restarted), "not restarted. log: #{log}"
      assert {:ok, _} = Machine.submit(restarted, "after restart", timeout: 10_000)
    end
  end

  describe "drain" do
    defp post_chat do
      body = %{"model" => "super-pi-workspace", "messages" => [%{"role" => "user", "content" => "hi"}]}

      conn(:post, "/v1/chat/completions", Jason.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> Router.call(Router.init([]))
    end

    test "accepting toggles" do
      assert Drain.accepting?()
      Drain.stop_accepting()
      refute Drain.accepting?()
      Drain.resume()
      assert Drain.accepting?()
    end

    test "the gateway refuses turns with 503 and Retry-After, and /ready reports it" do
      assert conn(:get, "/ready") |> Router.call(Router.init([])) |> Map.fetch!(:status) == 200
      Drain.stop_accepting()

      conn = post_chat()
      assert conn.status == 503
      assert get_resp_header(conn, "retry-after") == ["1"]
      assert %{"error" => %{"code" => "shutting_down"}} = Jason.decode!(conn.resp_body)

      assert conn(:get, "/ready") |> Router.call(Router.init([])) |> Map.fetch!(:status) == 503
      # Liveness and metrics stay up while draining.
      assert conn(:get, "/health") |> Router.call(Router.init([])) |> Map.fetch!(:status) == 200
      assert conn(:get, "/v1/models") |> Router.call(Router.init([])) |> Map.fetch!(:status) == 200

      Drain.resume()
      assert post_chat().status == 200
    end

    test "RPC refuses new sessions and turns, but not reads" do
      Drain.stop_accepting()
      call = fn method, params -> RPC.handle_rpc_payload(Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}), RPC.new_client_state()) |> elem(0) end

      assert %{"error" => %{"code" => -32005}} = call.("session.open", %{})
      assert %{"error" => %{"code" => -32005}} = call.("session.submit", %{"conversation_id" => 1, "text" => "x"})
      refute match?(%{"error" => %{"code" => -32005}}, call.("session.context", %{"conversation_id" => 1}))
    end

    test "drain returns at once when no turn is running, and waits for a running one" do
      conv = SuperPi.Durable.Storage.create_conversation!()
      {:ok, pid} = Locator.ensure_started(conv.id, [extensions: [], llm_responder: fn _p, _c -> Process.sleep(700) && {:ok, Faults.text_msg("done")} end], supervision: :local)

      assert Drain.busy_conversations() == []
      assert :drained = Drain.drain(2_000)
      Drain.resume()

      task = Task.async(fn -> Machine.submit(pid, "slow", timeout: 10_000) end)
      Process.sleep(200)
      assert conv.id in Drain.busy_conversations()

      {micros, result} = :timer.tc(fn -> Drain.drain(5_000) end)
      assert result == :drained
      assert div(micros, 1000) >= 300
      assert {:ok, _} = Task.await(task, 5_000)
    end

    test "drain gives up at the timeout and names the busy conversations" do
      conv = SuperPi.Durable.Storage.create_conversation!()
      {:ok, pid} = Locator.ensure_started(conv.id, [extensions: [], llm_responder: fn _p, _c -> Process.sleep(1_500) && {:ok, Faults.text_msg("done")} end], supervision: :local)

      task = Task.async(fn -> Machine.submit(pid, "slow", timeout: 10_000) end)
      Process.sleep(200)

      assert {:timeout, ids} = Drain.drain(300)
      assert conv.id in ids
      assert {:ok, _} = Task.await(task, 5_000)
    end
  end
end
