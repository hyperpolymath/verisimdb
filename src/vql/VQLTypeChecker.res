// SPDX-License-Identifier: PMPL-1.0-or-later
// VQL Type Checker - Dependent Type Verification
//
// Validates queries that use the PROOF clause require dependent-type
// verification to ensure correctness before execution.

module AST = VQLParser.AST
module Error = VQLError

// ============================================================================
// Type Context
// ============================================================================

type contractInfo = {
  name: string,
  proofType: AST.proofType,
  requiredFields: array<string>,
  constraints: array<constraint>,
}

and constraint =
  | FieldMustExist(string)
  | FieldMustBeType(string, primitiveType)
  | ModalityRequired(AST.modality)
  | MinimumSelectivity(float)
  | MaxDriftThreshold(float)

and primitiveType =
  | TString
  | TInt
  | TFloat
  | TBool
  | TArray(primitiveType)
  | TVector(int) // Fixed-size vector
  | TUuid

type typeContext = {
  contracts: Js.Dict.t<contractInfo>,
  availableModalities: array<AST.modality>,
  strictMode: bool,
}

// ============================================================================
// Type Checking
// ============================================================================

type typeCheckResult = Result<unit, Error.typeError>

let makeTypeContext = (~contracts: Js.Dict.t<contractInfo>=Js.Dict.empty(), ~strictMode=true, ()): typeContext => {
  {
    contracts: contracts,
    availableModalities: [Graph, Vector, Tensor, Semantic, Document, Temporal],
    strictMode: strictMode,
  }
}

let checkQuery = (query: AST.query, context: typeContext): typeCheckResult => {
  // Check if PROOF clause is present
  switch query.proof {
  | None => Ok() // No proof clause, no dependent-type checking needed
  | Some(proofSpec) => {
      // Verify contract exists
      switch Js.Dict.get(context.contracts, proofSpec.contractName) {
      | None =>
        Error({
          kind: Error.ContractNotFound(proofSpec.contractName),
          hexad_id: None,
          modality: None,
          context: `Contract '${proofSpec.contractName}' not found in registry`,
        })
      | Some(contractInfo) => {
          // Verify proof type matches
          if contractInfo.proofType != proofSpec.proofType {
            Error({
              kind: Error.TypeMismatch({
                expected: proofTypeToString(contractInfo.proofType),
                found: proofTypeToString(proofSpec.proofType),
              }),
              hexad_id: None,
              modality: None,
              context: `Contract '${proofSpec.contractName}' expects ${proofTypeToString(contractInfo.proofType)} proof`,
            })
          } else {
            // Verify constraints
            checkConstraints(query, contractInfo, context)
          }
        }
      }
    }
  }
}

let checkConstraints = (
  query: AST.query,
  contractInfo: contractInfo,
  _context: typeContext,
): typeCheckResult => {
  // Check each constraint
  let results = contractInfo.constraints->Belt.Array.map(constraint => {
    switch constraint {
    | FieldMustExist(field) => checkFieldExists(query, field)
    | FieldMustBeType(field, expectedType) => checkFieldType(query, field, expectedType)
    | ModalityRequired(modality) => checkModalityRequired(query, modality)
    | MinimumSelectivity(threshold) => checkSelectivity(query, threshold)
    | MaxDriftThreshold(threshold) => checkDriftThreshold(query, threshold)
    }
  })

  // Aggregate results - fail if any constraint fails
  results->Belt.Array.reduce(Ok(), (acc, result) => {
    switch (acc, result) {
    | (Ok(), Ok()) => Ok()
    | (Error(e), _) => Error(e)
    | (_, Error(e)) => Error(e)
    }
  })
}

let checkFieldExists = (query: AST.query, field: string): typeCheckResult => {
  // This is simplified - in real implementation, would analyze WHERE clause
  // to see if field is referenced
  switch query.where {
  | None =>
    Error({
      kind: Error.MissingTypeAnnotation(field),
      hexad_id: None,
      modality: None,
      context: `Required field '${field}' not found in query`,
    })
  | Some(_condition) =>
    // In real implementation: analyze condition tree for field reference
    Ok()
  }
}

let checkFieldType = (
  _query: AST.query,
  _field: string,
  _expectedType: primitiveType,
): typeCheckResult => {
  // Simplified - would analyze condition to infer field type
  Ok()
}

let checkModalityRequired = (query: AST.query, modality: AST.modality): typeCheckResult => {
  let hasModality = query.modalities->Belt.Array.some(m => m == modality || m == All)

  if hasModality {
    Ok()
  } else {
    Error({
      kind: Error.ContractViolation({
        contract: "modality-requirement",
        reason: `Contract requires ${modalityToString(modality)} modality`,
      }),
      hexad_id: None,
      modality: Some(modalityToString(modality)),
      context: `Query must include ${modalityToString(modality)} modality`,
    })
  }
}

let checkSelectivity = (_query: AST.query, _threshold: float): typeCheckResult => {
  // Simplified - would estimate query selectivity
  Ok()
}

let checkDriftThreshold = (query: AST.query, threshold: float): typeCheckResult => {
  // Check if drift policy allows threshold
  switch query.source {
  | Federation(_pattern, Some(driftPolicy)) => {
      switch driftPolicy {
      | Strict => Ok() // Strict always satisfies low drift
      | Repair => Ok() // Repair ensures low drift
      | Tolerate =>
        // Tolerate might exceed threshold
        Error({
          kind: Error.ContractViolation({
            contract: "drift-threshold",
            reason: `Drift policy TOLERATE may exceed threshold ${Belt.Float.toString(threshold)}`,
          }),
          hexad_id: None,
          modality: None,
          context: "Use STRICT or REPAIR drift policy for low-drift guarantees",
        })
      | Latest => Ok() // Latest gets most recent, drift irrelevant
      }
    }
  | Federation(_pattern, None) =>
    // No drift policy specified, might violate threshold
    Error({
      kind: Error.ContractViolation({
        contract: "drift-threshold",
        reason: "No drift policy specified",
      }),
      hexad_id: None,
      modality: None,
      context: "Specify STRICT or REPAIR drift policy",
    })
  | Hexad(_) | Store(_) => Ok() // Single source, no drift
  }
}

// ============================================================================
// Proof Generation Verification
// ============================================================================

type proofGenerationResult = Result<proofPlan, Error.typeError>

and proofPlan = {
  contract: string,
  proofType: AST.proofType,
  witnessFields: array<string>,
  circuit: string, // ZKP circuit identifier
  estimatedTimeMs: int,
}

let planProofGeneration = (query: AST.query, _context: typeContext): proofGenerationResult => {
  switch query.proof {
  | None =>
    Error({
      kind: Error.MissingTypeAnnotation("proof"),
      hexad_id: None,
      modality: None,
      context: "No PROOF clause in query",
    })
  | Some(proofSpec) => {
      // Plan proof generation
      let plan = {
        contract: proofSpec.contractName,
        proofType: proofSpec.proofType,
        witnessFields: extractWitnessFields(query),
        circuit: proofTypeToCircuit(proofSpec.proofType),
        estimatedTimeMs: estimateProofTime(proofSpec.proofType),
      }
      Ok(plan)
    }
  }
}

let extractWitnessFields = (query: AST.query): array<string> => {
  // Extract fields from WHERE clause that will be part of ZKP witness
  switch query.where {
  | None => []
  | Some(condition) => extractFieldsFromCondition(condition)
  }
}

let rec extractFieldsFromCondition = (condition: AST.condition): array<string> => {
  switch condition {
  | Simple(simpleCondition) => {
      switch simpleCondition {
      | FieldCondition(field, _, _) => [field]
      | FulltextContains(_) => ["fulltext"]
      | FulltextMatches(_) => ["fulltext"]
      | VectorSimilar(_, _) => ["embedding"]
      | GraphPattern(_) => ["graph_pattern"]
      }
    }
  | And(left, right) =>
    extractFieldsFromCondition(left)->Js.Array2.concat(extractFieldsFromCondition(right))
  | Or(left, right) =>
    extractFieldsFromCondition(left)->Js.Array2.concat(extractFieldsFromCondition(right))
  | Not(cond) => extractFieldsFromCondition(cond)
  }
}

let proofTypeToCircuit = (proofType: AST.proofType): string => {
  switch proofType {
  | Existence => "existence-proof-v1"
  | Citation => "citation-proof-v1"
  | Access => "access-control-v1"
  | Integrity => "integrity-check-v1"
  | Provenance => "provenance-chain-v1"
  | Custom => "custom-circuit"
  }
}

let estimateProofTime = (proofType: AST.proofType): int => {
  // Rough estimates in milliseconds
  switch proofType {
  | Existence => 50
  | Citation => 100
  | Access => 150
  | Integrity => 200
  | Provenance => 300
  | Custom => 500
  }
}

// ============================================================================
// Utility Functions
// ============================================================================

let proofTypeToString = (pt: AST.proofType): string => {
  switch pt {
  | Existence => "EXISTENCE"
  | Citation => "CITATION"
  | Access => "ACCESS"
  | Integrity => "INTEGRITY"
  | Provenance => "PROVENANCE"
  | Custom => "CUSTOM"
  }
}

let modalityToString = (m: AST.modality): string => {
  switch m {
  | Graph => "GRAPH"
  | Vector => "VECTOR"
  | Tensor => "TENSOR"
  | Semantic => "SEMANTIC"
  | Document => "DOCUMENT"
  | Temporal => "TEMPORAL"
  | All => "*"
  }
}

let primitiveTypeToString = (pt: primitiveType): string => {
  switch pt {
  | TString => "String"
  | TInt => "Int"
  | TFloat => "Float"
  | TBool => "Bool"
  | TArray(inner) => `Array<${primitiveTypeToString(inner)}>`
  | TVector(dim) => `Vector<${Belt.Int.toString(dim)}>`
  | TUuid => "UUID"
  }
}

// ============================================================================
// Public API
// ============================================================================

let createDefaultContext = (): typeContext => {
  makeTypeContext(~strictMode=true, ())
}

let registerContract = (
  context: typeContext,
  name: string,
  info: contractInfo,
): typeContext => {
  let newContracts = Js.Dict.fromArray(Js.Dict.entries(context.contracts))
  Js.Dict.set(newContracts, name, info)
  {...context, contracts: newContracts}
}

// Export for testing
let testCreateConstraint = (
  constraintType: string,
  param: string,
): option<constraint> => {
  switch constraintType {
  | "FieldMustExist" => Some(FieldMustExist(param))
  | "ModalityRequired" =>
    switch param {
    | "GRAPH" => Some(ModalityRequired(Graph))
    | "VECTOR" => Some(ModalityRequired(Vector))
    | "SEMANTIC" => Some(ModalityRequired(Semantic))
    | _ => None
    }
  | _ => None
  }
}
