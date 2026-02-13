// SPDX-License-Identifier: PMPL-1.0-or-later
// Example VQL queries for the playground.

type example = {
  label: string,
  query: string,
  vqlDt: bool,
}

let examples = [
  {
    label: "Basic graph query",
    query: "SELECT GRAPH\nFROM HEXAD\nWHERE type = 'Person'\nLIMIT 10",
    vqlDt: false,
  },
  {
    label: "Vector similarity search",
    query: "SELECT VECTOR\nFROM HEXAD\nWHERE SIMILAR TO [0.1, 0.2, 0.3]\nLIMIT 5",
    vqlDt: false,
  },
  {
    label: "Multi-modality query",
    query: "SELECT GRAPH, VECTOR, DOCUMENT\nFROM HEXAD\nWHERE name CONTAINS 'machine learning'\nORDER BY score DESC\nLIMIT 20",
    vqlDt: false,
  },
  {
    label: "Graph traversal",
    query: "SELECT GRAPH\nFROM HEXAD\nTRAVERSE relates_to\nDEPTH 3\nWHERE type = 'Concept'\nLIMIT 50",
    vqlDt: false,
  },
  {
    label: "Temporal query",
    query: "SELECT TEMPORAL\nFROM HEXAD\nAT TIME '2026-01-01T00:00:00Z'\nWHERE id = 'entity-123'\nLIMIT 1",
    vqlDt: false,
  },
  {
    label: "Full-text search",
    query: "SELECT DOCUMENT\nFROM HEXAD\nWHERE body CONTAINS 'multimodal database'\nORDER BY score DESC\nLIMIT 10",
    vqlDt: false,
  },
  {
    label: "Explain plan",
    query: "EXPLAIN SELECT GRAPH, VECTOR, SEMANTIC\nFROM HEXAD\nWHERE type = 'Article'\nLIMIT 100",
    vqlDt: false,
  },
  {
    label: "Federation query",
    query: "SELECT GRAPH\nFROM FEDERATION STORE 'remote-cluster-1'\nHEXAD\nWHERE region = 'eu-west'\nLIMIT 25",
    vqlDt: false,
  },
  // VQL-DT examples
  {
    label: "Proof of existence (VQL-DT)",
    query: "SELECT SEMANTIC\nFROM HEXAD\nPROOF EXISTENCE\nTHRESHOLD 0.95\nWHERE type = 'Certificate'\nLIMIT 10",
    vqlDt: true,
  },
  {
    label: "ZKP verification (VQL-DT)",
    query: "SELECT SEMANTIC, DOCUMENT\nFROM HEXAD\nPROOF ZKP\nTHRESHOLD 0.99\nWHERE classification = 'confidential'\nLIMIT 5",
    vqlDt: true,
  },
  {
    label: "PLONK proof (VQL-DT)",
    query: "SELECT SEMANTIC\nFROM HEXAD\nPROOF PLONK\nTHRESHOLD 1.0\nWHERE provenance = 'verified'\nLIMIT 10",
    vqlDt: true,
  },
  {
    label: "Consistency check (VQL-DT)",
    query: "SELECT GRAPH, SEMANTIC\nFROM HEXAD\nPROOF CONSISTENCY\nTHRESHOLD 0.9\nWHERE DRIFT THRESHOLD 0.1\nLIMIT 20",
    vqlDt: true,
  },
]

let forMode = (vqlDt: bool): array<example> =>
  examples->Array.filter(e => !e.vqlDt || vqlDt)
