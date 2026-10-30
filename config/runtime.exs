import Config

# stdio servers (`rpc --stdio`, `mcp`) use stdout for protocol messages only. Logs go to stderr.
if System.get_env("SUPER_PI_LOG_STDERR") in ["1", "true"] do
  config :logger, :default_handler, config: %{type: :standard_error}
end

# Export traces over OTLP/HTTP when an endpoint is given, for example http://localhost:4318.
# Other OTEL_* variables (OTEL_SERVICE_NAME, OTEL_RESOURCE_ATTRIBUTES) are read by the SDK.
if endpoint = System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT") do
  config :opentelemetry, traces_exporter: :otlp
  config :opentelemetry_exporter, otlp_protocol: :http_protobuf, otlp_endpoint: endpoint
end

# --- Storage ---------------------------------------------------------------------------------
#
# SUPER_PI_STORAGE_BACKEND=postgres uses a separate PostgreSQL instance (single node or managed).
#   DATABASE_URL                 ecto://user:pass@host:5432/db  (required)
#   SUPER_PI_DB_SSL              disable (default) | require | verify-full
#                                `sslmode=` in DATABASE_URL is read when this is unset
#                                (disable, require; verify-ca and verify-full mean verify-full)
#   SUPER_PI_DB_SSL_CA           CA bundle file for verify-full (default: the system CA store)
#   SUPER_PI_DB_SSL_SNI          server name to verify (default: the host of DATABASE_URL)
#   SUPER_PI_DB_SSL_CERT/_KEY    client certificate and key, for servers that require them
#   POOL_SIZE                    connections per node (default 10)
#   SUPER_PI_DB_QUEUE_TARGET     ms a checkout may wait before the pool sheds load (default 50)
#   SUPER_PI_DB_QUEUE_INTERVAL   ms window for the queue target (default 1000)
#   SUPER_PI_DB_IPV6             true to connect over IPv6
#   SUPER_PI_AUTO_MIGRATE        true | false, overrides the per-environment default
#
# Transaction-mode connection poolers (pgbouncer pool_mode=transaction) are not supported:
# Oban listens with LISTEN/NOTIFY and the driver prepares statements per connection.
# Use a direct connection, or a pooler in session mode.
case System.get_env("SUPER_PI_STORAGE_BACKEND") do
  "postgres" ->
    raw_url =
      System.get_env("DATABASE_URL") ||
        raise "DATABASE_URL environment variable is required when SUPER_PI_STORAGE_BACKEND=postgres"

    uri = URI.parse(raw_url)
    query = URI.decode_query(uri.query || "")

    ssl_mode =
      case System.get_env("SUPER_PI_DB_SSL") || Map.get(query, "sslmode") || "disable" do
        mode when mode in ["disable", "require", "verify-full"] -> mode
        mode when mode in ["verify-ca", "verify_full", "verify_ca"] -> "verify-full"
        mode when mode in ["allow", "prefer"] -> "require"
        other -> raise "SUPER_PI_DB_SSL must be disable, require or verify-full, got: #{inspect(other)}"
      end

    # `sslmode` is read here, not by the driver, so drop it from the URL.
    database_url =
      uri
      |> Map.put(:query, query |> Map.delete("sslmode") |> then(&if(&1 == %{}, do: nil, else: URI.encode_query(&1))))
      |> URI.to_string()

    client_cert =
      case {System.get_env("SUPER_PI_DB_SSL_CERT"), System.get_env("SUPER_PI_DB_SSL_KEY")} do
        {cert, key} when is_binary(cert) and is_binary(key) -> [certfile: cert, keyfile: key]
        _ -> []
      end

    ssl_opts =
      case ssl_mode do
        "disable" ->
          [ssl: false]

        "require" ->
          # Encrypts the connection but does not check the server certificate.
          [ssl: [verify: :verify_none] ++ client_cert]

        "verify-full" ->
          host = System.get_env("SUPER_PI_DB_SSL_SNI") || uri.host || raise "DATABASE_URL has no host"

          trust =
            case System.get_env("SUPER_PI_DB_SSL_CA") do
              nil -> [cacerts: :public_key.cacerts_get()]
              file -> [cacertfile: file]
            end

          [
            ssl:
              [
                verify: :verify_peer,
                server_name_indication: String.to_charlist(host),
                customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
              ] ++ trust ++ client_cert
          ]
      end

    config :super_pi,
      storage_backend: :postgres,
      ecto_repos: [SuperPi.Repo.Postgres]

    config :super_pi,
           SuperPi.Repo.Postgres,
           [
             url: database_url,
             pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
             queue_target: String.to_integer(System.get_env("SUPER_PI_DB_QUEUE_TARGET") || "50"),
             queue_interval: String.to_integer(System.get_env("SUPER_PI_DB_QUEUE_INTERVAL") || "1000")
           ] ++
             ssl_opts ++
             if(System.get_env("SUPER_PI_DB_IPV6") in ["1", "true"], do: [socket_options: [:inet6]], else: [])

    # `SUPER_PI_STORAGE_BACKEND=postgres mix test` runs the suite on PostgreSQL.
    if config_env() == :test do
      config :super_pi, SuperPi.Repo.Postgres, pool: Ecto.Adapters.SQL.Sandbox
      config :super_pi, Oban, testing: :manual
    end

    config :super_pi, Oban,
      engine: Oban.Engines.Basic,
      repo: SuperPi.Repo.Postgres

  _ ->
    cond do
      db_path = System.get_env("SUPER_PI_SQLITE_PATH") ->
        config :super_pi, SuperPi.Repo.SQLite, database: db_path

      # A release must not use the path baked in at compile time (the build machine's checkout).
      config_env() == :prod ->
        dir = :filename.basedir(:user_data, "super_pi") |> to_string()
        File.mkdir_p!(dir)
        config :super_pi, SuperPi.Repo.SQLite, database: Path.join(dir, "super_pi.db")

      true ->
        :ok
    end
end

case System.get_env("SUPER_PI_AUTO_MIGRATE") do
  value when value in ["1", "true"] -> config :super_pi, auto_migrate: true
  value when value in ["0", "false"] -> config :super_pi, auto_migrate: false
  _ -> :ok
end
