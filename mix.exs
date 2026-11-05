defmodule SuperPi.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/oleksandr/super-pi-beam"

  def project do
    [
      app: :super_pi,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      dialyzer: dialyzer(),
      description: "Durable, crash-resilient general-purpose agent framework for Elixir and the BEAM.",
      package: package(),
      docs: docs(),
      homepage_url: @source_url,
      source_url: @source_url,
      releases: [
        super_pi: [
          include_executables_for: [:unix],
          applications: [runtime_tools: :permanent]
        ]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :runtime_tools],
      mod: {SuperPi.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Durable Storage & State Machines
      {:ecto_sql, "~> 3.12"},
      {:ecto_sqlite3, "~> 0.17"},
      {:postgrex, "~> 0.19"},
      {:oban, "~> 2.18"},
      {:fsmx, "~> 0.5"},
      {:jsonpatch, "~> 2.2"},
      {:libgraph, "~> 0.16"},
      {:uniq, "~> 0.6"},

      # HTTP, Streaming LLM, & JSON
      {:req, "~> 0.5"},
      {:finch, "~> 0.19"},
      {:bandit, "~> 1.6"},
      {:plug, "~> 1.16"},
      {:jason, "~> 1.4"},
      {:floki, "~> 0.37"},
      {:tzdata, "~> 1.2"},
      {:jaxon, "~> 2.0"},
      {:nimble_options, "~> 1.1"},

      # Safe Execution Environment & Native Rustler NIF
      {:exile, "~> 0.10"},
      {:muontrap, "~> 2.0"},
      {:rustler, "~> 0.35", runtime: false},

      # TUI, PubSub, Cluster, & Telemetry
      {:owl, "~> 0.12"},
      {:phoenix_pubsub, "~> 2.1"},
      {:telemetry, "~> 1.3"},
      {:libcluster, "~> 3.4"},
      {:horde, "~> 0.9"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_metrics_prometheus_core, "~> 1.2"},
      {:opentelemetry_api, "~> 1.4"},
      {:opentelemetry, "~> 1.5"},
      {:opentelemetry_exporter, "~> 1.8"},

      # Testing & Property-Based Verification
      {:stream_data, "~> 1.1", only: [:dev, :test]},

      # Linting & Documentation
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.2", only: [:dev], runtime: false},
      {:ex_doc, "~> 0.37", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      name: :super_pi,
      licenses: ["MIT"],
      files: ~w(lib priv/repo .formatter.exs mix.exs README* LICENSE* CHANGELOG*),
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: ["README.md", "CHANGELOG.md"]
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      lint: [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "credo --only warning",
        "cmd mkdir -p priv/plts",
        "dialyzer"
      ],
      "lint:quick": [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "credo --only warning"
      ]
    ]
  end

  defp dialyzer do
    [
      plt_core_path: "priv/plts",
      plt_file: {:no_warn, "priv/plts/dialyzer.plt"}
    ]
  end
end
