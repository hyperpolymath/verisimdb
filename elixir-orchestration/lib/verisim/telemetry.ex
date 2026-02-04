# SPDX-License-Identifier: PMPL-1.0-or-later

defmodule VeriSim.Telemetry do
  @moduledoc """
  Telemetry - Metrics and observability for VeriSim.

  Defines telemetry events and metric collectors.
  """

  use Supervisor
  require Logger

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Returns the list of telemetry events.
  """
  def events do
    [
      # Entity events
      [:verisim, :entity, :create],
      [:verisim, :entity, :update],
      [:verisim, :entity, :delete],

      # Query events
      [:verisim, :query, :start],
      [:verisim, :query, :stop],
      [:verisim, :query, :exception],

      # Drift events
      [:verisim, :drift, :detected],
      [:verisim, :drift, :normalized],

      # Rust client events
      [:verisim, :rust_client, :request],
      [:verisim, :rust_client, :response]
    ]
  end

  @doc """
  Returns metric definitions for Telemetry.Metrics.
  """
  def metrics do
    [
      # Entity metrics
      Telemetry.Metrics.counter("verisim.entity.create.count"),
      Telemetry.Metrics.counter("verisim.entity.update.count"),
      Telemetry.Metrics.counter("verisim.entity.delete.count"),

      # Query metrics
      Telemetry.Metrics.counter("verisim.query.count"),
      Telemetry.Metrics.distribution("verisim.query.duration",
        unit: {:native, :millisecond}
      ),

      # Drift metrics
      Telemetry.Metrics.last_value("verisim.drift.score"),
      Telemetry.Metrics.counter("verisim.drift.detected.count"),
      Telemetry.Metrics.counter("verisim.drift.normalized.count"),

      # Rust client metrics
      Telemetry.Metrics.counter("verisim.rust_client.request.count"),
      Telemetry.Metrics.distribution("verisim.rust_client.response.duration",
        unit: {:native, :millisecond}
      ),
      Telemetry.Metrics.counter("verisim.rust_client.error.count"),

      # System metrics
      Telemetry.Metrics.last_value("vm.memory.total", unit: :byte),
      Telemetry.Metrics.last_value("vm.total_run_queue_lengths.total"),
      Telemetry.Metrics.last_value("vm.system_counts.process_count")
    ]
  end

  defp periodic_measurements do
    [
      # VM measurements
      {__MODULE__, :measure_vm_memory, []},
      {__MODULE__, :measure_vm_queues, []},
      {__MODULE__, :measure_vm_processes, []},

      # VeriSim measurements
      {__MODULE__, :measure_entity_count, []},
      {__MODULE__, :measure_drift_status, []}
    ]
  end

  @doc false
  def measure_vm_memory do
    memory = :erlang.memory()
    :telemetry.execute([:vm, :memory], %{total: memory[:total]}, %{})
  end

  @doc false
  def measure_vm_queues do
    total = :erlang.statistics(:total_run_queue_lengths)
    :telemetry.execute([:vm, :total_run_queue_lengths], %{total: total}, %{})
  end

  @doc false
  def measure_vm_processes do
    count = :erlang.system_info(:process_count)
    :telemetry.execute([:vm, :system_counts], %{process_count: count}, %{})
  end

  @doc false
  def measure_entity_count do
    # Count entity servers
    count =
      case Registry.count(VeriSim.EntityRegistry) do
        n when is_integer(n) -> n
        _ -> 0
      end

    :telemetry.execute([:verisim, :entities], %{count: count}, %{})
  end

  @doc false
  def measure_drift_status do
    # Get drift status from monitor
    case GenServer.whereis(VeriSim.DriftMonitor) do
      nil -> :ok
      _pid ->
        case VeriSim.DriftMonitor.status() do
          %{overall_health: health} ->
            score = health_to_score(health)
            :telemetry.execute([:verisim, :drift], %{score: score}, %{})
          _ -> :ok
        end
    end
  end

  defp health_to_score(:healthy), do: 0.0
  defp health_to_score(:warning), do: 0.3
  defp health_to_score(:degraded), do: 0.6
  defp health_to_score(:critical), do: 0.9
  defp health_to_score(_), do: 0.0
end
