# SPDX-License-Identifier: MPL-2.0
#
# VQLBridge built-in parser throughput.  In test env the Deno/Node
# subprocess isn't started so all parse* calls hit the pure-Elixir
# fallback — exactly the path we want to bench (no IPC variance).

{:ok, _} = Application.ensure_all_started(:verisim)

alias VeriSim.Query.VQLBridge

queries = %{
  simple_select: "SELECT GRAPH FROM HEXAD abc-123",
  multi_modality: "SELECT GRAPH, VECTOR, TENSOR, DOCUMENT, SEMANTIC FROM HEXAD abc-123",
  with_where: "SELECT GRAPH FROM HEXAD abc-123 WHERE drift_score > 0.5",
  with_proof: "SELECT GRAPH FROM HEXAD abc-123 PROOF EXISTENCE(entity-001)",
  with_limit: "SELECT GRAPH FROM HEXAD abc-123 LIMIT 100",
  insert_mutation: "INSERT HEXAD WITH GRAPH {} AND VECTOR {}",
  update_mutation: "UPDATE HEXAD abc-123 SET GRAPH {}",
  delete_mutation: "DELETE HEXAD abc-123"
}

Benchee.run(
  %{
    "parse — simple SELECT" => fn -> VQLBridge.parse(queries.simple_select) end,
    "parse — 5-modality SELECT" => fn -> VQLBridge.parse(queries.multi_modality) end,
    "parse — SELECT + WHERE" => fn -> VQLBridge.parse(queries.with_where) end,
    "parse — SELECT + LIMIT" => fn -> VQLBridge.parse(queries.with_limit) end,
    "parse_slipstream — valid (no PROOF)" => fn ->
      VQLBridge.parse_slipstream(queries.simple_select)
    end,
    "parse_slipstream — rejected (has PROOF)" => fn ->
      VQLBridge.parse_slipstream(queries.with_proof)
    end,
    "parse_dependent — valid (with PROOF)" => fn ->
      VQLBridge.parse_dependent(queries.with_proof)
    end,
    "parse_mutation — INSERT" => fn -> VQLBridge.parse_mutation(queries.insert_mutation) end,
    "parse_mutation — UPDATE" => fn -> VQLBridge.parse_mutation(queries.update_mutation) end,
    "parse_mutation — DELETE" => fn -> VQLBridge.parse_mutation(queries.delete_mutation) end,
    "parse_statement — Query routing" => fn ->
      VQLBridge.parse_statement(queries.simple_select)
    end,
    "parse_statement — Mutation routing" => fn ->
      VQLBridge.parse_statement(queries.insert_mutation)
    end
  },
  warmup: 2,
  time: 5,
  memory_time: 1,
  print: [fast_warning: false],
  formatters: [
    Benchee.Formatters.Console,
    {Benchee.Formatters.JSON, file: "bench/results/vql_bridge.json"}
  ]
)
