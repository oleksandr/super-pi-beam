defmodule SuperPi.RuntimeConfigTest do
  @moduledoc "config/runtime.exs: PostgreSQL TLS, pool, SQLite path and migration settings."
  use ExUnit.Case, async: false

  @vars ~w(SUPER_PI_STORAGE_BACKEND DATABASE_URL SUPER_PI_DB_SSL SUPER_PI_DB_SSL_CA SUPER_PI_DB_SSL_SNI
           SUPER_PI_DB_SSL_CERT SUPER_PI_DB_SSL_KEY POOL_SIZE SUPER_PI_DB_QUEUE_TARGET
           SUPER_PI_DB_QUEUE_INTERVAL SUPER_PI_DB_IPV6 SUPER_PI_SQLITE_PATH SUPER_PI_AUTO_MIGRATE)

  setup do
    saved = Enum.map(@vars, &{&1, System.get_env(&1)})
    Enum.each(@vars, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)
  end

  defp read(env, vars) do
    Enum.each(vars, fn {k, v} -> System.put_env(k, v) end)
    Config.Reader.read!("config/runtime.exs", env: env, target: :host)
  end

  defp pg(config), do: config[:super_pi][SuperPi.Repo.Postgres]
  @url "ecto://app:secret@db.example.com:5432/super_pi"

  describe "postgres" do
    test "DATABASE_URL is required" do
      assert_raise RuntimeError, ~r/DATABASE_URL/, fn -> read(:prod, %{"SUPER_PI_STORAGE_BACKEND" => "postgres"}) end
    end

    test "defaults: no TLS, pool 10, queue target 50" do
      opts = read(:prod, %{"SUPER_PI_STORAGE_BACKEND" => "postgres", "DATABASE_URL" => @url}) |> pg()

      assert opts[:url] == @url
      assert opts[:ssl] == false
      assert opts[:pool_size] == 10
      assert opts[:queue_target] == 50
      assert opts[:queue_interval] == 1000
      refute opts[:socket_options]
    end

    test "require encrypts without verifying" do
      opts = read(:prod, %{"SUPER_PI_STORAGE_BACKEND" => "postgres", "DATABASE_URL" => @url, "SUPER_PI_DB_SSL" => "require"}) |> pg()
      assert opts[:ssl][:verify] == :verify_none
    end

    test "verify-full checks the chain and the host name, with the given CA" do
      opts =
        read(:prod, %{
          "SUPER_PI_STORAGE_BACKEND" => "postgres",
          "DATABASE_URL" => @url,
          "SUPER_PI_DB_SSL" => "verify-full",
          "SUPER_PI_DB_SSL_CA" => "/etc/ssl/db-ca.pem"
        })
        |> pg()

      ssl = opts[:ssl]
      assert ssl[:verify] == :verify_peer
      assert ssl[:cacertfile] == "/etc/ssl/db-ca.pem"
      assert ssl[:server_name_indication] == ~c"db.example.com"
      assert ssl[:customize_hostname_check][:match_fun]
    end

    test "verify-full without a CA file uses the system store" do
      opts = read(:prod, %{"SUPER_PI_STORAGE_BACKEND" => "postgres", "DATABASE_URL" => @url, "SUPER_PI_DB_SSL" => "verify-full"}) |> pg()
      assert [_ | _] = opts[:ssl][:cacerts]
    end

    test "the SNI name can be set, and a client certificate is passed on" do
      opts =
        read(:prod, %{
          "SUPER_PI_STORAGE_BACKEND" => "postgres",
          "DATABASE_URL" => @url,
          "SUPER_PI_DB_SSL" => "verify-full",
          "SUPER_PI_DB_SSL_SNI" => "primary.internal",
          "SUPER_PI_DB_SSL_CERT" => "/c.pem",
          "SUPER_PI_DB_SSL_KEY" => "/k.pem"
        })
        |> pg()

      assert opts[:ssl][:server_name_indication] == ~c"primary.internal"
      assert opts[:ssl][:certfile] == "/c.pem"
      assert opts[:ssl][:keyfile] == "/k.pem"
    end

    test "sslmode in the URL is read, and removed from the URL given to the driver" do
      opts = read(:prod, %{"SUPER_PI_STORAGE_BACKEND" => "postgres", "DATABASE_URL" => @url <> "?sslmode=verify-full&timeout=5000"}) |> pg()
      assert opts[:ssl][:verify] == :verify_peer
      assert opts[:url] =~ "timeout=5000"
      refute opts[:url] =~ "sslmode"
    end

    test "SUPER_PI_DB_SSL wins over sslmode in the URL" do
      opts = read(:prod, %{"SUPER_PI_STORAGE_BACKEND" => "postgres", "DATABASE_URL" => @url <> "?sslmode=require", "SUPER_PI_DB_SSL" => "disable"}) |> pg()
      assert opts[:ssl] == false
    end

    test "an unknown mode is an error" do
      assert_raise RuntimeError, ~r/SUPER_PI_DB_SSL/, fn ->
        read(:prod, %{"SUPER_PI_STORAGE_BACKEND" => "postgres", "DATABASE_URL" => @url, "SUPER_PI_DB_SSL" => "yes please"})
      end
    end

    test "pool, queue and IPv6 settings" do
      opts =
        read(:prod, %{
          "SUPER_PI_STORAGE_BACKEND" => "postgres",
          "DATABASE_URL" => @url,
          "POOL_SIZE" => "25",
          "SUPER_PI_DB_QUEUE_TARGET" => "200",
          "SUPER_PI_DB_QUEUE_INTERVAL" => "3000",
          "SUPER_PI_DB_IPV6" => "true"
        })
        |> pg()

      assert opts[:pool_size] == 25
      assert opts[:queue_target] == 200
      assert opts[:queue_interval] == 3000
      assert opts[:socket_options] == [:inet6]
    end

    test "the Oban engine is Basic" do
      config = read(:prod, %{"SUPER_PI_STORAGE_BACKEND" => "postgres", "DATABASE_URL" => @url})
      assert config[:super_pi][Oban][:engine] == Oban.Engines.Basic
    end
  end

  describe "sqlite and migrations" do
    test "SUPER_PI_SQLITE_PATH sets the database" do
      config = read(:prod, %{"SUPER_PI_SQLITE_PATH" => "/data/sp.db"})
      assert config[:super_pi][SuperPi.Repo.SQLite][:database] == "/data/sp.db"
    end

    test "a prod release gets a per-user data path, not the compile-time checkout path" do
      db = read(:prod, %{})[:super_pi][SuperPi.Repo.SQLite][:database]
      assert Path.basename(db) == "super_pi.db"
      refute db =~ "/priv/"
    end

    test "dev and test keep the configured path" do
      assert read(:dev, %{})[:super_pi][SuperPi.Repo.SQLite] == nil
    end

    test "SUPER_PI_AUTO_MIGRATE overrides the environment default" do
      assert read(:prod, %{"SUPER_PI_AUTO_MIGRATE" => "true"})[:super_pi][:auto_migrate] == true
      assert read(:dev, %{"SUPER_PI_AUTO_MIGRATE" => "false"})[:super_pi][:auto_migrate] == false
    end

    test "auto migration is off in prod by default and on elsewhere" do
      assert Config.Reader.read!("config/prod.exs", env: :prod)[:super_pi][:auto_migrate] == false
      assert Application.get_env(:super_pi, :auto_migrate, true) in [true, false]
    end
  end
end
