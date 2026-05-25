# SPDX-License-Identifier: MPL-2.0
#
# Per-modality query dispatch latency through VeriSim.QueryRouter.
# All real backend calls return {:error, _} in this env (no Rust core),
# which means we're measuring the pure dispatch + stats-update overhead.

{:ok, _} = Application.ensure_all_started(:verisim)

alias VeriSim.QueryRouter

Benchee.run(
  %{
    "query :text" => fn -> QueryRouter.query(:text, "benchee-probe", limit: 10) end,
    "query :vector" => fn -> QueryRouter.query(:vector, [0.1, 0.2, 0.3], k: 5) end,
    "query :graph" => fn -> QueryRouter.query(:graph, %{start: "e-1"}) end,
    "query :semantic (single type)" => fn ->
      QueryRouter.query(:semantic, %{types: ["http://example.org/Doc"]})
    end,
    "query :semantic (3 types)" => fn ->
      QueryRouter.query(:semantic, %{
        types: [
          "http://example.org/A",
          "http://example.org/B",
          "http://example.org/C"
        ]
      })
    end,
    "query :multi (text + vector)" => fn ->
      QueryRouter.query(:multi, %{text: "AI", vector: [0.5, 0.5, 0.5]})
    end,
    "query :unknown_type — error path" => fn ->
      QueryRouter.query(:bogus, %{})
    end,
    "stats/0 — read snapshot" => fn ->
      QueryRouter.stats()
    end
  },
  warmup: 2,
  time: 5,
  memory_time: 1,
  print: [fast_warning: false],
  formatters: [
    Benchee.Formatters.Console,
    {Benchee.Formatters.JSON, file: "bench/results/query_router.json"}
  ]
)
