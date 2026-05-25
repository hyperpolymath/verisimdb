# SPDX-License-Identifier: MPL-2.0
#
# VQLExecutor explain-plan generation + statement dispatch latency.
# The :explain path is fully local (Rust planner unreachable in test env
# → fallback), so this measures pure executor logic.

{:ok, _} = Application.ensure_all_started(:verisim)

alias VeriSim.Query.VQLExecutor

simple_ast = %{modalities: [:graph], source: {:octad, "x"}}

multi_modality_ast = %{
  modalities: [:graph, :vector, :tensor, :document, :semantic, :temporal, :provenance, :spatial],
  source: {:octad, "x"}
}

proof_ast = %{
  modalities: [:graph, :vector],
  source: {:octad, "x"},
  proof: [
    %{type: "EXISTENCE", target: "a"},
    %{type: "INTEGRITY", target: "b"}
  ]
}

federation_ast = %{
  modalities: [:graph, :vector],
  source: {:federation, "/universities/*", :tolerate}
}

Benchee.run(
  %{
    "execute/2 :explain — single-modality octad" => fn ->
      VQLExecutor.execute(simple_ast, explain: true)
    end,
    "execute/2 :explain — 8-modality octad" => fn ->
      VQLExecutor.execute(multi_modality_ast, explain: true)
    end,
    "execute/2 :explain — with 2 PROOF specs" => fn ->
      VQLExecutor.execute(proof_ast, explain: true)
    end,
    "execute/2 :explain — federation fan-out" => fn ->
      VQLExecutor.execute(federation_ast, explain: true)
    end,
    "execute_statement/2 — TAG: Query dispatch" => fn ->
      VQLExecutor.execute_statement(%{TAG: "Query", _0: simple_ast}, explain: true)
    end,
    "execute_statement/2 — TAG: Mutation Bogus" => fn ->
      VQLExecutor.execute_statement(%{TAG: "Mutation", _0: %{TAG: "Bogus"}})
    end,
    "execute_string/2 — parse + explain valid query" => fn ->
      VQLExecutor.execute_string("SELECT GRAPH FROM HEXAD abc-123", explain: true)
    end,
    "execute_string/2 — parse error path" => fn ->
      VQLExecutor.execute_string("BOGUS NOT VALID", [])
    end
  },
  warmup: 2,
  time: 5,
  memory_time: 1,
  print: [fast_warning: false],
  formatters: [
    Benchee.Formatters.Console,
    {Benchee.Formatters.JSON, file: "bench/results/vql_executor.json"}
  ]
)
