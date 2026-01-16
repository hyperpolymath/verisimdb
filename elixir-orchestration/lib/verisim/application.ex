# SPDX-License-Identifier: AGPL-3.0-or-later

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
      VeriSim.SchemaRegistry
    ]

    opts = [strategy: :one_for_one, name: VeriSim.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
