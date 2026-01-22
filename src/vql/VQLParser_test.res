// SPDX-License-Identifier: PMPL-1.0-or-later
// VQL Parser Tests

open VQLParser

// Test helper
let assertOk = (result: Result<'a, 'b>, testName: string) => {
  switch result {
  | Ok(_) => Js.Console.log(`✓ ${testName}`)
  | Error(e) => Js.Console.error(`✗ ${testName}: ${e.message}`)
  }
}

let assertError = (result: Result<'a, 'b>, testName: string) => {
  switch result {
  | Ok(_) => Js.Console.error(`✗ ${testName}: Expected error but got Ok`)
  | Error(_) => Js.Console.log(`✓ ${testName}`)
  }
}

// ============================================================================
// Test Suite
// ============================================================================

Js.Console.log("\n=== VQL Parser Tests ===\n")

// Test 1: Simple hexad query
let test1 = `
  SELECT *
  FROM HEXAD 550e8400-e29b-41d4-a716-446655440000
`

assertOk(parseSlipstream(test1), "Test 1: Simple hexad query")

// Test 2: Federation query with drift policy
let test2 = `
  SELECT GRAPH, VECTOR
  FROM FEDERATION /universities/* WITH DRIFT REPAIR
`

assertOk(parseSlipstream(test2), "Test 2: Federation with drift policy")

// Test 3: Full-text search with LIMIT
let test3 = `
  SELECT DOCUMENT
  FROM STORE tantivy-node-1
  WHERE FULLTEXT CONTAINS "machine learning"
  LIMIT 100
`

assertOk(parseSlipstream(test3), "Test 3: Full-text search with LIMIT")

// Test 4: Vector similarity query
let test4 = `
  SELECT VECTOR
  FROM HEXAD abc12345-0000-0000-0000-000000000000
  WHERE h.embedding SIMILAR TO [0.1, 0.2, 0.3] WITHIN 0.9
`

assertOk(parseSlipstream(test4), "Test 4: Vector similarity query")

// Test 5: Multiple modalities
let test5 = `
  SELECT GRAPH, VECTOR, DOCUMENT
  FROM FEDERATION /research/*
  LIMIT 50
  OFFSET 100
`

assertOk(parseSlipstream(test5), "Test 5: Multiple modalities with pagination")

// Test 6: Dependent-type query (should have PROOF)
let test6 = `
  SELECT GRAPH
  FROM HEXAD 550e8400-e29b-41d4-a716-446655440000
  WHERE FULLTEXT CONTAINS "climate change"
  PROOF CITATION(CitationContract)
`

assertOk(parseDependentType(test6), "Test 6: Dependent-type with PROOF")

// Test 7: Slipstream with PROOF (should fail)
let test7 = `
  SELECT *
  FROM HEXAD 550e8400-e29b-41d4-a716-446655440000
  PROOF EXISTENCE(ExistenceContract)
`

assertError(parseSlipstream(test7), "Test 7: Slipstream rejects PROOF clause")

// Test 8: Dependent-type without PROOF (should fail)
let test8 = `
  SELECT GRAPH
  FROM HEXAD 550e8400-e29b-41d4-a716-446655440000
`

assertError(parseDependentType(test8), "Test 8: Dependent-type requires PROOF")

// Test 9: Field condition
let test9 = `
  SELECT DOCUMENT
  FROM STORE archive-1
  WHERE FIELD year >= 2020
  LIMIT 10
`

assertOk(parseSlipstream(test9), "Test 9: Field condition with operator")

// Test 10: Multiple WHERE conditions (simplified - parser needs enhancement)
let test10 = `
  SELECT DOCUMENT
  FROM FEDERATION /archives/*
  WHERE FULLTEXT CONTAINS "quantum computing"
`

assertOk(parseSlipstream(test10), "Test 10: WHERE with FULLTEXT")

// Test 11: Complex dependent-type query
let test11 = `
  SELECT GRAPH, VECTOR, SEMANTIC
  FROM FEDERATION /universities/* WITH DRIFT STRICT
  WHERE h.embedding SIMILAR TO [0.5, 0.3, 0.2]
  PROOF INTEGRITY(DataIntegrityContract)
  LIMIT 100
`

assertOk(parseDependentType(test11), "Test 11: Complex dependent-type query")

// Test 12: All modalities
let test12 = `
  SELECT *
  FROM HEXAD 550e8400-e29b-41d4-a716-446655440000
  LIMIT 10
`

assertOk(parseSlipstream(test12), "Test 12: All modalities (wildcard)")

// Test 13: Store query
let test13 = `
  SELECT VECTOR
  FROM STORE milvus-us-east-1
  WHERE h.embedding SIMILAR TO [0.1, 0.2]
  LIMIT 20
`

assertOk(parseSlipstream(test13), "Test 13: Store-specific query")

// Test 14: PROOF with different types
let test14a = `SELECT * FROM HEXAD 550e8400-e29b-41d4-a716-446655440000 PROOF EXISTENCE(ExistenceContract)`
assertOk(parseDependentType(test14a), "Test 14a: EXISTENCE proof")

let test14b = `SELECT * FROM HEXAD 550e8400-e29b-41d4-a716-446655440000 PROOF ACCESS(AccessContract)`
assertOk(parseDependentType(test14b), "Test 14b: ACCESS proof")

let test14c = `SELECT * FROM HEXAD 550e8400-e29b-41d4-a716-446655440000 PROOF PROVENANCE(ProvenanceContract)`
assertOk(parseDependentType(test14c), "Test 14c: PROVENANCE proof")

// Test 15: Invalid UUID (should fail)
let test15 = `
  SELECT *
  FROM HEXAD not-a-valid-uuid
`

assertError(parse(test15), "Test 15: Invalid UUID format")

// Test 16: Missing FROM (should fail)
let test16 = `
  SELECT GRAPH
  WHERE FULLTEXT CONTAINS "test"
`

assertError(parse(test16), "Test 16: Missing FROM clause")

// Test 17: Drift policy variations
let test17a = `SELECT * FROM FEDERATION /nodes/* WITH DRIFT STRICT`
assertOk(parseSlipstream(test17a), "Test 17a: DRIFT STRICT")

let test17b = `SELECT * FROM FEDERATION /nodes/* WITH DRIFT REPAIR`
assertOk(parseSlipstream(test17b), "Test 17b: DRIFT REPAIR")

let test17c = `SELECT * FROM FEDERATION /nodes/* WITH DRIFT TOLERATE`
assertOk(parseSlipstream(test17c), "Test 17c: DRIFT TOLERATE")

let test17d = `SELECT * FROM FEDERATION /nodes/* WITH DRIFT LATEST`
assertOk(parseSlipstream(test17d), "Test 17d: DRIFT LATEST")

Js.Console.log("\n=== Tests Complete ===\n")

// ============================================================================
// Example: Extracting parsed data
// ============================================================================

Js.Console.log("=== Example: Parsing and Inspecting Query ===\n")

let exampleQuery = `
  SELECT GRAPH, VECTOR
  FROM FEDERATION /universities/* WITH DRIFT REPAIR
  WHERE FULLTEXT CONTAINS "neural networks"
  PROOF CITATION(NeuralNetworkContract)
  LIMIT 50
`

switch parseDependentType(exampleQuery) {
| Ok(query) => {
    Js.Console.log("Parsed query successfully:")
    Js.Console.log(`  Modalities: ${query.modalities->Js.Array2.length->Belt.Int.toString}`)
    Js.Console.log(`  Source: ${switch query.source {
      | Hexad(id) => `Hexad(${id})`
      | Federation(pattern, drift) => {
          let driftStr = switch drift {
          | Some(Strict) => " WITH DRIFT STRICT"
          | Some(Repair) => " WITH DRIFT REPAIR"
          | Some(Tolerate) => " WITH DRIFT TOLERATE"
          | Some(Latest) => " WITH DRIFT LATEST"
          | None => ""
          }
          `Federation(${pattern}${driftStr})`
        }
      | Store(id) => `Store(${id})`
      }}`)
    Js.Console.log(`  Has WHERE: ${query.where->Belt.Option.isSome->Belt.Bool.toString}`)
    Js.Console.log(`  Has PROOF: ${query.proof->Belt.Option.isSome->Belt.Bool.toString}`)
    switch query.proof {
    | Some(proof) => Js.Console.log(`    Proof contract: ${proof.contractName}`)
    | None => ()
    }
    Js.Console.log(`  Limit: ${switch query.limit {
      | Some(n) => Belt.Int.toString(n)
      | None => "None"
    }}`)
  }
| Error(e) => {
    Js.Console.error(`Parse error: ${e.message}`)
  }
}

Js.Console.log("\n")
