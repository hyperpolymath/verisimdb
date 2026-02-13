// SPDX-License-Identifier: PMPL-1.0-or-later
// VQL keyword definitions shared across syntax highlighting, completion, and linting.

let keywords = [
  "SELECT", "FROM", "WHERE", "PROOF", "LIMIT", "OFFSET", "ORDER", "BY",
  "GROUP", "HAVING", "AS", "AND", "OR", "NOT", "IN", "BETWEEN", "LIKE",
  "EXISTS", "CONTAINS", "SIMILAR", "TO", "TRAVERSE", "DEPTH", "THRESHOLD",
  "DRIFT", "CONSISTENCY", "AT", "TIME", "EXPLAIN", "INSERT", "UPDATE",
  "DELETE", "SET", "INTO", "VALUES", "CREATE", "DROP", "ALTER", "JOIN",
  "ON", "WITH", "FEDERATION", "STORE", "HEXAD", "ALL", "ASC", "DESC",
  "COUNT", "SUM", "AVG", "MIN", "MAX", "DISTINCT", "ANALYZE",
]

let modalities = [
  "GRAPH", "VECTOR", "TENSOR", "SEMANTIC", "DOCUMENT", "TEMPORAL",
]

let proofTypes = [
  "EXISTENCE", "CONSISTENCY", "INTEGRITY", "AUTHENTICITY",
  "PROVENANCE", "ZKP", "PLONK",
]

/// VQL-DT specific keywords (only active in VQL-DT mode).
let vqlDtKeywords = [
  "PROOF", "THRESHOLD", "VERIFY", "CERTIFY", "ATTEST",
  "WITNESS", "CIRCUIT", "COMMITMENT",
]

let isKeyword = word => keywords->Array.includes(String.toUpperCase(word))
let isModality = word => modalities->Array.includes(String.toUpperCase(word))
let isProofType = word => proofTypes->Array.includes(String.toUpperCase(word))
