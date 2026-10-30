defmodule SuperPi.PostgresTLSTest do
  @moduledoc """
  Connects to a real PostgreSQL with each TLS mode, using the options that `config/runtime.exs`
  builds. Needs a server with `ssl = on` and a certificate for `localhost` / `127.0.0.1`:

      SUPER_PI_TLS_TEST_URL=ecto://postgres@127.0.0.1:5432/db \\
      SUPER_PI_TLS_TEST_CA=/path/ca.pem SUPER_PI_TLS_TEST_WRONG_CA=/path/other-ca.pem \\
        mix test --only postgres test/super_pi/postgres_tls_test.exs
  """
  use ExUnit.Case, async: false

  @moduletag :postgres

  @url System.get_env("SUPER_PI_TLS_TEST_URL")
  @ca System.get_env("SUPER_PI_TLS_TEST_CA")
  @wrong_ca System.get_env("SUPER_PI_TLS_TEST_WRONG_CA")

  if is_nil(@url) or is_nil(@ca) or is_nil(@wrong_ca) do
    @moduletag skip: "set SUPER_PI_TLS_TEST_URL, SUPER_PI_TLS_TEST_CA and SUPER_PI_TLS_TEST_WRONG_CA"
  end

  @vars ~w(SUPER_PI_STORAGE_BACKEND DATABASE_URL SUPER_PI_DB_SSL SUPER_PI_DB_SSL_CA SUPER_PI_DB_SSL_SNI)

  setup do
    saved = Enum.map(@vars, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)
  end

  # Returns `{:ok, ssl_in_use?}` or `{:error, reason}`.
  defp connect(env) do
    System.put_env("SUPER_PI_STORAGE_BACKEND", "postgres")
    System.put_env("DATABASE_URL", @url)
    Enum.each(["SUPER_PI_DB_SSL", "SUPER_PI_DB_SSL_CA", "SUPER_PI_DB_SSL_SNI"], &System.delete_env/1)
    Enum.each(env, fn {k, v} -> System.put_env(k, v) end)

    opts =
      Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)[:super_pi][SuperPi.Repo.Postgres]
      |> Keyword.merge(pool_size: 1, name: nil, timeout: 3_000, connect_timeout: 3_000, backoff_type: :stop, pool: DBConnection.ConnectionPool)

    Process.flag(:trap_exit, true)

    case SuperPi.Repo.Postgres.start_link(opts) do
      {:ok, pid} ->
        SuperPi.Repo.Postgres.put_dynamic_repo(pid)

        try do
          case SuperPi.Repo.Postgres.query("SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()", []) do
            {:ok, %{rows: [[ssl]]}} -> {:ok, ssl}
            {:error, error} -> {:error, error}
          end
        catch
          :exit, reason -> {:error, reason}
        after
          SuperPi.Repo.Postgres.put_dynamic_repo(SuperPi.Repo.Postgres)
          # A refused handshake stops the repo on its own.
          if Process.alive?(pid), do: Supervisor.stop(pid)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  test "disable connects without TLS" do
    assert {:ok, false} = connect(%{"SUPER_PI_DB_SSL" => "disable"})
  end

  test "require connects with TLS" do
    assert {:ok, true} = connect(%{"SUPER_PI_DB_SSL" => "require"})
  end

  test "verify-full connects when the CA signed the server certificate" do
    assert {:ok, true} = connect(%{"SUPER_PI_DB_SSL" => "verify-full", "SUPER_PI_DB_SSL_CA" => @ca})
  end

  test "verify-full refuses a server whose certificate a different CA signed" do
    assert {:error, _} = connect(%{"SUPER_PI_DB_SSL" => "verify-full", "SUPER_PI_DB_SSL_CA" => @wrong_ca})
  end

  test "verify-full refuses a host name that is not in the certificate" do
    assert {:error, _} = connect(%{"SUPER_PI_DB_SSL" => "verify-full", "SUPER_PI_DB_SSL_CA" => @ca, "SUPER_PI_DB_SSL_SNI" => "evil.example.com"})
  end

  test "require does not check the certificate, so a wrong CA is no obstacle" do
    assert {:ok, true} = connect(%{"SUPER_PI_DB_SSL" => "require", "SUPER_PI_DB_SSL_CA" => @wrong_ca})
  end
end
