# SPDX-License-Identifier: MPL-2.0
#
# Steady-state perf of VeriSim.DriftMonitor's report/status/sweep loop.
# Run with: mix run bench/drift_monitor_bench.exs
#
# Captures average wall-clock per operation under a fresh GenServer.
# JSON output is written to bench/results/drift_monitor.json for CI diff.

# Ensure the supervision tree (DriftMonitor + EntityRegistry + ...) is up.
{:ok, _} = Application.ensure_all_started(:verisim)

alias VeriSim.DriftMonitor

# Stabilise: drain any pending sweep messages.
:ok = DriftMonitor.sweep()
_ = DriftMonitor.status()

# Pre-populate entity drift to give status/0 + sweep some work.
seed_entities = fn n ->
  for i <- 1..n do
    DriftMonitor.report_drift("seed-#{i}", :rand.uniform() * 0.4, :semantic_vector)
  end
end

seed_entities.(100)

Benchee.run(
  %{
    "report_drift/3 (semantic_vector, score=0.15)" => fn ->
      DriftMonitor.report_drift("e-#{System.unique_integer([:positive])}", 0.15, :semantic_vector)
    end,
    "report_drift/3 (high-score → triggers normalization path)" => fn ->
      DriftMonitor.report_drift(
        "e-crit-#{System.unique_integer([:positive])}",
        0.85,
        :semantic_vector
      )
    end,
    "status/0 — read-only call over 100+ entities" => fn ->
      DriftMonitor.status()
    end,
    "entity_history/1 — read on known entity" => fn ->
      DriftMonitor.entity_history("seed-1")
    end,
    "entity_history/1 — miss on unknown entity" => fn ->
      DriftMonitor.entity_history("never-reported")
    end,
    "sweep/0 — manual sweep cast" => fn ->
      DriftMonitor.sweep()
    end
  },
  warmup: 2,
  time: 5,
  memory_time: 1,
  reduction_time: 1,
  print: [fast_warning: false],
  formatters: [
    Benchee.Formatters.Console,
    {Benchee.Formatters.JSON, file: "bench/results/drift_monitor.json"}
  ]
)
