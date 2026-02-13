# SPDX-License-Identifier: PMPL-1.0-or-later

defmodule VeriSim.Application do
  @moduledoc """
  VeriSim Application - OTP application entry point.

  Starts the supervision tree for VeriSim orchestration.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Telemetry supervisor
      VeriSim.Telemetry,

      # Registry for entity servers
      {Registry, keys: :unique, name: VeriSim.EntityRegistry},

      # Dynamic supervisor for entity servers
      {DynamicSupervisor,
        name: VeriSim.EntitySupervisor,
        strategy: :one_for_one,
        max_restarts: 100,
        max_seconds: 60},

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
      VeriSim.Federation.Resolver
    ]

    opts = [strategy: :one_for_one, name: VeriSim.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
