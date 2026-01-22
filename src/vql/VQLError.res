// SPDX-License-Identifier: PMPL-1.0-or-later

/**
 * VQL Error Types - Structured error representation
 *
 * Provides comprehensive error types for all VQL failure modes:
 * - Parse errors (syntax)
 * - Type errors (dependent-type verification)
 * - Runtime errors (execution)
 * - Modality-specific errors
 * - Federation errors
 */

type position = {
  line: int,
  column: int,
  offset: int,
}

type span = {
  start: position,
  end_: position,
}

// ============================================================================
// Parse Errors
// ============================================================================

type parseErrorKind =
  | UnexpectedToken({expected: array<string>, found: string})
  | UnterminatedString
  | InvalidNumber(string)
  | InvalidModality(string)
  | InvalidDriftPolicy(string)
  | InvalidProofType(string)
  | MissingFromClause
  | MissingSelectClause
  | InvalidGraphPattern(string)
  | InvalidVectorExpression(string)
  | InvalidSemanticContract(string)

type parseError = {
  kind: parseErrorKind,
  span: span,
  source: string, // The original query string
  hint: option<string>,
}

// ============================================================================
// Type Errors (Dependent-Type Path)
// ============================================================================

type typeErrorKind =
  | ContractNotFound(string)
  | ContractViolation({contract: string, reason: string})
  | ProofGenerationFailed({contract: string, error: string})
  | ProofVerificationFailed({contract: string, reason: string})
  | TypeMismatch({expected: string, found: string})
  | MissingTypeAnnotation(string)
  | CircularDependency(array<string>)

type typeError = {
  kind: typeErrorKind,
  hexad_id: option<string>,
  modality: option<string>,
  context: string,
}

// ============================================================================
// Runtime Errors
// ============================================================================

type runtimeErrorKind =
  | StoreUnavailable({store_id: string, reason: string})
  | QueryTimeout({duration_ms: int, limit_ms: int})
  | DriftDetected({hexad_id: string, details: string})
  | PermissionDenied({user_id: option<string>, resource: string})
  | ResourceExhausted({resource: string, limit: string})
  | InvalidHexadId(string)
  | NetworkError({endpoint: string, status: option<int>})
  | InternalError(string)

type runtimeError = {
  kind: runtimeErrorKind,
  query_id: option<string>,
  timestamp: Js.Date.t,
  recoverable: bool,
}

// ============================================================================
// Modality-Specific Errors
// ============================================================================

type graphError =
  | MalformedRDF(string)
  | InvalidTriplePattern(string)
  | CycleDetected(array<string>)
  | PredicateNotFound(string)
  | TraversalDepthExceeded(int)

type vectorError =
  | DimensionMismatch({expected: int, found: int})
  | InvalidDistanceMetric(string)
  | EmbeddingNotFound(string)
  | ANNIndexUnavailable(string)

type tensorError =
  | ShapeMismatch({expected: array<int>, found: array<int>})
  | NumericOverflow(string)
  | InvalidOperation(string)
  | UnsupportedDtype(string)

type semanticError =
  | InvalidContract(string)
  | ZKPVerificationFailed(string)
  | WitnessGenerationFailed(string)
  | ContractExpired(string)

type documentError =
  | InvalidFullTextQuery(string)
  | UnsupportedLanguage(string)
  | IndexCorrupted(string)

type temporalError =
  | InvalidTimestamp(string)
  | VersionNotFound({hexad_id: string, timestamp: string})
  | MerkleVerificationFailed(string)
  | TemporalConflict(string)

type modalityError =
  | GraphError(graphError)
  | VectorError(vectorError)
  | TensorError(tensorError)
  | SemanticError(semanticError)
  | DocumentError(documentError)
  | TemporalError(temporalError)

// ============================================================================
// Federation Errors
// ============================================================================

type federationErrorKind =
  | RemoteStoreUnreachable({endpoint: string, timeout_ms: int})
  | PartialResults({succeeded: array<string>, failed: array<string>})
  | CrossOrgAccessDenied({org_id: string, resource: string})
  | ByzantineFaultDetected({suspicious_nodes: array<string>})
  | ConsensusTimeout({participants: int, duration_ms: int})
  | FederationPolicyViolation(string)

type federationError = {
  kind: federationErrorKind,
  federation_pattern: string,
  affected_stores: array<string>,
}

// ============================================================================
// Composite Error Type
// ============================================================================

type vqlError =
  | ParseError(parseError)
  | TypeError(typeError)
  | RuntimeError(runtimeError)
  | ModalityError(modalityError)
  | FederationError(federationError)
  | MultipleErrors(array<vqlError>)

// ============================================================================
// Error Formatting
// ============================================================================

let formatPosition = (pos: position): string => {
  `${pos.line->Int.toString}:${pos.column->Int.toString}`
}

let formatSpan = (span: span): string => {
  `${formatPosition(span.start)}-${formatPosition(span.end_)}`
}

let formatParseError = (err: parseError): string => {
  let kindStr = switch err.kind {
  | UnexpectedToken({expected, found}) =>
    `Expected ${expected->Array.joinWith(", ", x => `'${x}'`)}, found '${found}'`
  | UnterminatedString => "Unterminated string literal"
  | InvalidNumber(num) => `Invalid number: '${num}'`
  | InvalidModality(mod) => `Invalid modality: '${mod}'. Valid: GRAPH, VECTOR, TENSOR, SEMANTIC, DOCUMENT, TEMPORAL`
  | InvalidDriftPolicy(policy) => `Invalid drift policy: '${policy}'. Valid: STRICT, REPAIR, TOLERATE, LATEST`
  | InvalidProofType(proof) => `Invalid proof type: '${proof}'. Valid: EXISTENCE, CITATION, ACCESS, INTEGRITY, PROVENANCE`
  | MissingFromClause => "Missing FROM clause"
  | MissingSelectClause => "Missing SELECT clause"
  | InvalidGraphPattern(pattern) => `Invalid graph pattern: '${pattern}'`
  | InvalidVectorExpression(expr) => `Invalid vector expression: '${expr}'`
  | InvalidSemanticContract(contract) => `Invalid semantic contract: '${contract}'`
  }

  let hintStr = switch err.hint {
  | Some(hint) => `\n  Hint: ${hint}`
  | None => ""
  }

  `Parse Error at ${formatSpan(err.span)}: ${kindStr}${hintStr}`
}

let formatTypeError = (err: typeError): string => {
  let kindStr = switch err.kind {
  | ContractNotFound(contract) => `Contract not found: '${contract}'`
  | ContractViolation({contract, reason}) => `Contract '${contract}' violated: ${reason}`
  | ProofGenerationFailed({contract, error}) => `Failed to generate proof for '${contract}': ${error}`
  | ProofVerificationFailed({contract, reason}) => `Proof verification failed for '${contract}': ${reason}`
  | TypeMismatch({expected, found}) => `Type mismatch: expected ${expected}, found ${found}`
  | MissingTypeAnnotation(field) => `Missing type annotation for field: '${field}'`
  | CircularDependency(cycle) => `Circular dependency detected: ${cycle->Array.joinWith(" → ", x => x)}`
  }

  let contextStr = switch (err.hexad_id, err.modality) {
  | (Some(hexad), Some(mod)) => ` [hexad: ${hexad}, modality: ${mod}]`
  | (Some(hexad), None) => ` [hexad: ${hexad}]`
  | (None, Some(mod)) => ` [modality: ${mod}]`
  | (None, None) => ""
  }

  `Type Error${contextStr}: ${kindStr}\n  Context: ${err.context}`
}

let formatRuntimeError = (err: runtimeError): string => {
  let kindStr = switch err.kind {
  | StoreUnavailable({store_id, reason}) => `Store '${store_id}' unavailable: ${reason}`
  | QueryTimeout({duration_ms, limit_ms}) => `Query timeout: exceeded ${limit_ms}ms (ran for ${duration_ms}ms)`
  | DriftDetected({hexad_id, details}) => `Drift detected for hexad '${hexad_id}': ${details}`
  | PermissionDenied({user_id, resource}) => {
      let user = switch user_id {
      | Some(id) => `user '${id}'`
      | None => "user"
      }
      `Permission denied: ${user} cannot access '${resource}'`
    }
  | ResourceExhausted({resource, limit}) => `Resource exhausted: ${resource} (limit: ${limit})`
  | InvalidHexadId(id) => `Invalid hexad ID: '${id}'`
  | NetworkError({endpoint, status}) => {
      let statusStr = switch status {
      | Some(code) => ` (HTTP ${code->Int.toString})`
      | None => ""
      }
      `Network error connecting to '${endpoint}'${statusStr}`
    }
  | InternalError(msg) => `Internal error: ${msg}`
  }

  let recoverable = if err.recoverable {
    " [recoverable]"
  } else {
    " [non-recoverable]"
  }

  `Runtime Error${recoverable}: ${kindStr}`
}

let formatModalityError = (err: modalityError): string => {
  switch err {
  | GraphError(ge) =>
    switch ge {
    | MalformedRDF(msg) => `Graph Error: Malformed RDF: ${msg}`
    | InvalidTriplePattern(pattern) => `Graph Error: Invalid triple pattern: '${pattern}'`
    | CycleDetected(path) => `Graph Error: Cycle detected: ${path->Array.joinWith(" → ", x => x)}`
    | PredicateNotFound(pred) => `Graph Error: Predicate not found: '${pred}'`
    | TraversalDepthExceeded(depth) => `Graph Error: Traversal depth exceeded: ${depth->Int.toString}`
    }
  | VectorError(ve) =>
    switch ve {
    | DimensionMismatch({expected, found}) => `Vector Error: Dimension mismatch: expected ${expected->Int.toString}, found ${found->Int.toString}`
    | InvalidDistanceMetric(metric) => `Vector Error: Invalid distance metric: '${metric}'`
    | EmbeddingNotFound(id) => `Vector Error: Embedding not found: '${id}'`
    | ANNIndexUnavailable(reason) => `Vector Error: ANN index unavailable: ${reason}`
    }
  | TensorError(te) =>
    switch te {
    | ShapeMismatch({expected, found}) => {
        let expStr = expected->Array.map(Int.toString)->Array.joinWith("×", x => x)
        let foundStr = found->Array.map(Int.toString)->Array.joinWith("×", x => x)
        `Tensor Error: Shape mismatch: expected [${expStr}], found [${foundStr}]`
      }
    | NumericOverflow(msg) => `Tensor Error: Numeric overflow: ${msg}`
    | InvalidOperation(op) => `Tensor Error: Invalid operation: '${op}'`
    | UnsupportedDtype(dtype) => `Tensor Error: Unsupported dtype: '${dtype}'`
    }
  | SemanticError(se) =>
    switch se {
    | InvalidContract(contract) => `Semantic Error: Invalid contract: '${contract}'`
    | ZKPVerificationFailed(reason) => `Semantic Error: ZKP verification failed: ${reason}`
    | WitnessGenerationFailed(reason) => `Semantic Error: Witness generation failed: ${reason}`
    | ContractExpired(contract) => `Semantic Error: Contract expired: '${contract}'`
    }
  | DocumentError(de) =>
    switch de {
    | InvalidFullTextQuery(query) => `Document Error: Invalid full-text query: '${query}'`
    | UnsupportedLanguage(lang) => `Document Error: Unsupported language: '${lang}'`
    | IndexCorrupted(index) => `Document Error: Index corrupted: '${index}'`
    }
  | TemporalError(te) =>
    switch te {
    | InvalidTimestamp(ts) => `Temporal Error: Invalid timestamp: '${ts}'`
    | VersionNotFound({hexad_id, timestamp}) => `Temporal Error: Version not found for hexad '${hexad_id}' at '${timestamp}'`
    | MerkleVerificationFailed(reason) => `Temporal Error: Merkle verification failed: ${reason}`
    | TemporalConflict(msg) => `Temporal Error: Temporal conflict: ${msg}`
    }
  }
}

let formatFederationError = (err: federationError): string => {
  let kindStr = switch err.kind {
  | RemoteStoreUnreachable({endpoint, timeout_ms}) => `Remote store unreachable: '${endpoint}' (timeout: ${timeout_ms->Int.toString}ms)`
  | PartialResults({succeeded, failed}) => {
      let succStr = succeeded->Array.joinWith(", ", x => x)
      let failStr = failed->Array.joinWith(", ", x => x)
      `Partial results: succeeded=[${succStr}], failed=[${failStr}]`
    }
  | CrossOrgAccessDenied({org_id, resource}) => `Cross-org access denied: org '${org_id}' cannot access '${resource}'`
  | ByzantineFaultDetected({suspicious_nodes}) => `Byzantine fault detected: suspicious nodes=[${suspicious_nodes->Array.joinWith(", ", x => x)}]`
  | ConsensusTimeout({participants, duration_ms}) => `Consensus timeout: ${participants->Int.toString} participants, ${duration_ms->Int.toString}ms`
  | FederationPolicyViolation(msg) => `Federation policy violation: ${msg}`
  }

  `Federation Error [${err.federation_pattern}]: ${kindStr}`
}

let format = (err: vqlError): string => {
  switch err {
  | ParseError(e) => formatParseError(e)
  | TypeError(e) => formatTypeError(e)
  | RuntimeError(e) => formatRuntimeError(e)
  | ModalityError(e) => formatModalityError(e)
  | FederationError(e) => formatFederationError(e)
  | MultipleErrors(errors) => {
      let header = `Multiple Errors (${errors->Array.length->Int.toString}):`
      let formatted = errors->Array.mapWithIndex((err, idx) => {
        `  ${(idx + 1)->Int.toString}. ${format(err)}`
      })
      [header]->Array.concat(formatted)->Array.joinWith("\n", x => x)
    }
  }
}

// ============================================================================
// Error Helpers
// ============================================================================

let isRecoverable = (err: vqlError): bool => {
  switch err {
  | RuntimeError(e) => e.recoverable
  | FederationError({kind: PartialResults(_)}) => true
  | FederationError({kind: RemoteStoreUnreachable(_)}) => true
  | _ => false
  }
}

let getErrorCode = (err: vqlError): string => {
  switch err {
  | ParseError(_) => "VQL_PARSE_ERROR"
  | TypeError(_) => "VQL_TYPE_ERROR"
  | RuntimeError({kind: StoreUnavailable(_)}) => "VQL_STORE_UNAVAILABLE"
  | RuntimeError({kind: QueryTimeout(_)}) => "VQL_QUERY_TIMEOUT"
  | RuntimeError({kind: DriftDetected(_)}) => "VQL_DRIFT_DETECTED"
  | RuntimeError({kind: PermissionDenied(_)}) => "VQL_PERMISSION_DENIED"
  | RuntimeError({kind: ResourceExhausted(_)}) => "VQL_RESOURCE_EXHAUSTED"
  | RuntimeError(_) => "VQL_RUNTIME_ERROR"
  | ModalityError(GraphError(_)) => "VQL_GRAPH_ERROR"
  | ModalityError(VectorError(_)) => "VQL_VECTOR_ERROR"
  | ModalityError(TensorError(_)) => "VQL_TENSOR_ERROR"
  | ModalityError(SemanticError(_)) => "VQL_SEMANTIC_ERROR"
  | ModalityError(DocumentError(_)) => "VQL_DOCUMENT_ERROR"
  | ModalityError(TemporalError(_)) => "VQL_TEMPORAL_ERROR"
  | FederationError(_) => "VQL_FEDERATION_ERROR"
  | MultipleErrors(_) => "VQL_MULTIPLE_ERRORS"
  }
}

let toJson = (err: vqlError): Js.Json.t => {
  Js.Dict.fromArray([
    ("error_code", Js.Json.string(getErrorCode(err))),
    ("message", Js.Json.string(format(err))),
    ("recoverable", Js.Json.boolean(isRecoverable(err))),
  ])->Js.Json.object_
}
