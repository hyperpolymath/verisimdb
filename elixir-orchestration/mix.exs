# SPDX-License-Identifier: MPL-2.0
# Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>

defmodule VeriSim.MixProject do
  use Mix.Project

  def project do
    [
      app: :verisim,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        "coveralls.json": :test
      ],
      test_coverage: [tool: ExCoveralls],
      releases: [
        verisim: [
          include_executables_for: [:unix],
          applications: [runtime_tools: :permanent]
        ]
      ],

      # Docs
      name: "VeriSim Orchestration",
      source_url: "https://gitlab.com/hyperpolymath/verisimdb",
      docs: [
        main: "VeriSim",
        extras: ["README.md"]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {VeriSim.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # HTTP client for Rust core communication
      {:req, "~> 0.5"},

      # HTTP server for orchestration API (telemetry, status)
      # >= 1.11.1 required for GHSA-rf5q-vwxw-gmrf (chunked-trailer DoS, High).
      {:bandit, "~> 1.11 and >= 1.11.1"},

      # Plug is a transitive of bandit but pinned directly to enforce the
      # GHSA-468c-vq7p-gh64 fix (multipart-header buffer exhaustion, High).
      {:plug, "~> 1.19 and >= 1.19.2"},

      # JSON encoding/decoding
      {:jason, "~> 1.4"},

      # Bundled CA certificates — pulled in to satisfy `Redix.Connector`
      # (and `mint`/`excoveralls`) which treat castore as an optional dep.
      # `mix compile --warnings-as-errors` flagged the unresolved
      # `CAStore.file_path/0` call site at `lib/redix/connector.ex:261`.
      {:castore, "~> 1.0"},

      # Telemetry and metrics
      {:telemetry, "~> 1.2"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},

      # Process registry
      {:horde, "~> 0.9"},

      # Testing
      {:ex_machina, "~> 2.7", only: :test},
      {:mox, "~> 1.0", only: :test},
      {:stream_data, "~> 1.1", only: [:test, :dev]},
      {:excoveralls, "~> 0.18", only: :test},

      # Benchmarking
      {:benchee, "~> 1.3", only: [:dev, :test]},
      {:benchee_html, "~> 1.0", only: [:dev, :test]},
      {:benchee_json, "~> 1.0", only: [:dev, :test]},

      # Optional: native protocol adapters for federation
      # These are only needed when using :wire protocol instead of HTTP
      # >= 0.22.2 required for GHSA-r73h-97w8-m54h (channel-name SQL
      # injection in Postgrex.Notifications.listen/3, High).
      {:postgrex, "~> 0.22 and >= 0.22.2", optional: true},
      {:redix, "~> 1.5", optional: true},
      {:exqlite, "~> 0.27", optional: true},

      # Development
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},

      # Override transitive dep to get OTP 25+ fix (erl_syntax:string/1 removed)
      {:parse_trans, "3.4.2", override: true}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"],
      test: ["test"],
      "test.watch": ["test.watch"],
      coverage: ["coveralls"],
      "coverage.html": ["coveralls.html"],
      bench: ["run -e 'VeriSim.Bench.run_all()'"]
    ]
  end
end
