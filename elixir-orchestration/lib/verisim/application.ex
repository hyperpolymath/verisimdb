# SPDX-License-Identifier: MPL-2.0

defmodule VeriSim.Application do
  @moduledoc """
  VeriSim Application - OTP application entry point.

  Starts the supervision tree for VeriSim orchestration.
  """

  use Application

  @doc """
  Initializes the local Hypatia scan index and starts the supervision tree.

  The application master owns the index so it outlives individual scan callers.
  Returns the result of `Supervisor.start_link/2`.
  """
  @impl true
  def start(_type, _args) do
    # Owned by this (application master) process so it outlives callers.
    VeriSim.Hypatia.ScanIngester.init_table()

    children = [
      # Telemetry supervisor
      VeriSim.Telemetry,

      # Registry for entity servers
      {Registry, keys: :unique, name: VeriSim.EntityRegistry},

      # Dynamic supervisor for entity servers
      {DynamicSupervisor,
       name: VeriSim.EntitySupervisor, strategy: :one_for_one, max_restarts: 100, max_seconds: 60},

      # Drift monitor
      VeriSim.DriftMonitor,

      # Query router
      VeriSim.QueryRouter,

      # Schema registry
      VeriSim.SchemaRegistry,

      # Consensus registry (must start before KRaftNode)
      {Registry, keys: :unique, name: VeriSim.Consensus.Registry},

      # KRaft consensus node (single-node bootstrap by default)
      {VeriSim.Consensus.KRaftNode,
       node_id: Application.get_env(:verisim, :kraft_node_id, "local"),
       peers: Application.get_env(:verisim, :kraft_peers, [])},

      # Federation resolver
      VeriSim.Federation.Resolver,

      # Health checker (periodic liveness probing)
      VeriSim.HealthChecker,

      # Orchestration HTTP API (telemetry, status endpoints)
      {Bandit,
       plug: VeriSim.Api.Router,
       ip: Application.get_env(:verisim, :orch_api_ip, {127, 0, 0, 1}),
       port: orch_api_port()}
    ]

    opts = [strategy: :rest_for_one, name: VeriSim.Supervisor, max_restarts: 10, max_seconds: 60]
    Supervisor.start_link(children, opts)
  end

  defp orch_api_port do
    case System.get_env("VERISIM_ORCH_PORT") do
      nil -> Application.get_env(:verisim, :orch_api_port, 4080)
      port -> String.to_integer(port)
    end
  end
end
