defmodule SuperPi.MixProject do
  use Mix.Project

  def project do
    [
      app: :super_pi,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
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
      {:jaxon, "~> 2.0"},
      {:nimble_options, "~> 1.1"},

      # Safe Execution Environment & Native Rustler NIF
      {:exile, "~> 0.10"},
      {:muontrap, "~> 1.5"},
      {:rustler, "~> 0.35", runtime: false},

      # TUI, PubSub, Cluster, & Telemetry
      {:owl, "~> 0.12"},
      {:phoenix_pubsub, "~> 2.1"},
      {:telemetry, "~> 1.3"},

      # Testing & Property-Based Verification
      {:stream_data, "~> 1.1", only: [:dev, :test]}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end
end
