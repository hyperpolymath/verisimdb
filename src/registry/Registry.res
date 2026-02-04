// SPDX-License-Identifier: PMPL-1.0-or-later
// ReScript Federation Registry
// The "tiny core" (<5k LOC) for universal federated knowledge

// ============================================================================
// Types
// ============================================================================

type hexadId = string

type storeId = string

type modalityType =
  | Graph
  | Vector
  | Tensor
  | Semantic
  | Document
  | Temporal

type storeLocation = {
  storeId: storeId,
  endpoint: string,
  modalities: array<modalityType>,
  trustLevel: float, // 0.0-1.0
  lastSeen: Js.Date.t,
  responseTimeMs: option<int>,
}

type hexadMapping = {
  hexadId: hexadId,
  locations: Js.Dict.t<storeLocation>, // modalityType -> storeLocation
  primaryStore: option<storeId>,
  created: Js.Date.t,
  modified: Js.Date.t,
}

type registryState = {
  mappings: Js.Dict.t<hexadMapping>, // hexadId -> hexadMapping
  stores: Js.Dict.t<storeLocation>, // storeId -> storeLocation
  config: registryConfig,
}

and registryConfig = {
  minTrustLevel: float,
  maxStoreDowntimeMs: int,
  replicationFactor: int,
  consistencyMode: consistencyMode,
}

and consistencyMode =
  | Strong // All replicas must agree
  | Eventual // Accept temporary inconsistency
  | Quorum // Majority must agree

// ============================================================================
// Registry Operations
// ============================================================================

let createRegistry = (~config: registryConfig): registryState => {
  {
    mappings: Js.Dict.empty(),
    stores: Js.Dict.empty(),
    config: config,
  }
}

let defaultConfig = (): registryConfig => {
  {
    minTrustLevel: 0.5,
    maxStoreDowntimeMs: 300_000, // 5 minutes
    replicationFactor: 3,
    consistencyMode: Quorum,
  }
}

// Register a new store
let registerStore = (
  registry: registryState,
  storeId: storeId,
  endpoint: string,
  modalities: array<modalityType>,
): registryState => {
  let location: storeLocation = {
    storeId: storeId,
    endpoint: endpoint,
    modalities: modalities,
    trustLevel: 1.0,
    lastSeen: Js.Date.make(),
    responseTimeMs: None,
  }

  let newStores = Js.Dict.fromArray(Js.Dict.entries(registry.stores))
  Js.Dict.set(newStores, storeId, location)

  {...registry, stores: newStores}
}

// Map a hexad to store locations
let mapHexad = (
  registry: registryState,
  hexadId: hexadId,
  locations: Js.Dict.t<storeLocation>,
): registryState => {
  let mapping: hexadMapping = {
    hexadId: hexadId,
    locations: locations,
    primaryStore: None,
    created: Js.Date.make(),
    modified: Js.Date.make(),
  }

  let newMappings = Js.Dict.fromArray(Js.Dict.entries(registry.mappings))
  Js.Dict.set(newMappings, hexadId, mapping)

  {...registry, mappings: newMappings}
}

// Get store locations for a hexad
let getHexadLocations = (
  registry: registryState,
  hexadId: hexadId,
): option<hexadMapping> => {
  Js.Dict.get(registry.mappings, hexadId)
}

// Find stores that have a specific modality
let findStoresByModality = (
  registry: registryState,
  modality: modalityType,
): array<storeLocation> => {
  registry.stores
  ->Js.Dict.values
  ->Belt.Array.keep(store => {
    store.modalities->Belt.Array.some(m => m == modality)
  })
}

// Select best store for a modality based on trust and response time
let selectBestStore = (
  registry: registryState,
  modality: modalityType,
): option<storeLocation> => {
  let candidates = findStoresByModality(registry, modality)

  if Belt.Array.length(candidates) == 0 {
    None
  } else {
    // Score stores by trust level and response time
    let scored = candidates->Belt.Array.map(store => {
      let trustScore = store.trustLevel
      let responseScore = switch store.responseTimeMs {
      | None => 0.5
      | Some(ms) => 1.0 -. (Belt.Int.toFloat(ms) /. 1000.0)->Js.Math.min_float(1.0)
      }
      let score = trustScore *. 0.7 +. responseScore *. 0.3
      (store, score)
    })

    // Sort by score descending
    let sorted = scored->Belt.Array.reverse->Belt.SortArray.stableSortBy(((_, scoreA), (_, scoreB)) => {
      Belt.Float.toInt((scoreB -. scoreA) *. 1000.0)
    })

    sorted->Belt.Array.get(0)->Belt.Option.map(((store, _)) => store)
  }
}

// Update store health metrics
let updateStoreHealth = (
  registry: registryState,
  storeId: storeId,
  responseTimeMs: int,
  success: bool,
): registryState => {
  switch Js.Dict.get(registry.stores, storeId) {
  | None => registry
  | Some(store) => {
      let newTrust = if success {
        Js.Math.min_float(store.trustLevel +. 0.05, 1.0)
      } else {
        Js.Math.max_float(store.trustLevel -. 0.1, 0.0)
      }

      let updatedStore = {
        ...store,
        trustLevel: newTrust,
        lastSeen: Js.Date.make(),
        responseTimeMs: Some(responseTimeMs),
      }

      let newStores = Js.Dict.fromArray(Js.Dict.entries(registry.stores))
      Js.Dict.set(newStores, storeId, updatedStore)

      {...registry, stores: newStores}
    }
  }
}

// Remove stores that haven't been seen recently
let pruneDeadStores = (registry: registryState): registryState => {
  let now = Js.Date.now()
  let maxDowntime = Belt.Int.toFloat(registry.config.maxStoreDowntimeMs)

  let liveStores = registry.stores
    ->Js.Dict.entries
    ->Belt.Array.keep(((_, store)) => {
      let timeSinceLastSeen = now -. Js.Date.getTime(store.lastSeen)
      timeSinceLastSeen < maxDowntime
    })
    ->Js.Dict.fromArray

  {...registry, stores: liveStores}
}

// ============================================================================
// Federation Queries
// ============================================================================

type federationQuery = {
  pattern: string, // e.g., "/universities/*"
  modalities: array<modalityType>,
  limit: int,
}

type queryResult = {
  storeId: storeId,
  hexadId: hexadId,
  modality: modalityType,
  data: Js.Json.t,
}

// Resolve a federation pattern to list of stores
let resolvePattern = (
  registry: registryState,
  pattern: string,
): array<storeLocation> => {
  // Simple pattern matching - in production would use regex
  if Js.String2.endsWith(pattern, "/*") {
    let prefix = Js.String2.slice(pattern, ~from=0, ~to_=Js.String2.length(pattern) - 2)

    registry.stores
    ->Js.Dict.values
    ->Belt.Array.keep(store => {
      Js.String2.startsWith(store.storeId, prefix)
    })
  } else {
    // Exact match
    switch Js.Dict.get(registry.stores, pattern) {
    | None => []
    | Some(store) => [store]
    }
  }
}

// Execute a federated query across multiple stores
let executeFederatedQuery = async (
  registry: registryState,
  query: federationQuery,
): Promise.t<array<queryResult>> => {
  let stores = resolvePattern(registry, query.pattern)

  // Filter stores by required modalities
  let eligibleStores = stores->Belt.Array.keep(store => {
    query.modalities->Belt.Array.every(modality => {
      store.modalities->Belt.Array.some(m => m == modality)
    })
  })

  // In production, would make parallel HTTP requests to each store
  // For now, return empty results
  Promise.resolve([])
}

// ============================================================================
// Consistency & Replication
// ============================================================================

type replicationStatus =
  | UpToDate
  | Stale({lagMs: int})
  | Diverged({conflictCount: int})

let checkReplicationStatus = (
  registry: registryState,
  hexadId: hexadId,
): replicationStatus => {
  // Check if hexad replicas are consistent across stores
  // In production, would query each store and compare versions
  UpToDate
}

// Trigger replication for a hexad
let replicateHexad = async (
  registry: registryState,
  hexadId: hexadId,
  sourceStore: storeId,
  targetStores: array<storeId>,
): Promise.t<Result.t<unit, string>> => {
  // Copy hexad from source to target stores
  // In production, would use HTTP API to fetch and push data
  Promise.resolve(Ok())
}

// ============================================================================
// Trust & Byzantine Fault Tolerance
// ============================================================================

type consensusResult<'a> = {
  value: 'a,
  agreement: float, // 0.0-1.0
  participants: array<storeId>,
}

// Achieve consensus across stores using quorum voting
let achieveConsensus = async (
  registry: registryState,
  stores: array<storeId>,
  getValue: storeId => Promise.t<option<'a>>,
): Promise.t<option<consensusResult<'a>>> => {
  // Fetch values from all stores
  // Count occurrences
  // Return value with quorum agreement
  // In production, would implement full Byzantine fault tolerance
  Promise.resolve(None)
}

// Detect Byzantine faults (malicious stores)
let detectByzantineFaults = (
  registry: registryState,
  hexadId: hexadId,
): array<storeId> => {
  // Compare responses from different stores
  // Flag stores with divergent data
  []
}

// ============================================================================
// Serialization
// ============================================================================

let modalityToString = (m: modalityType): string => {
  switch m {
  | Graph => "graph"
  | Vector => "vector"
  | Tensor => "tensor"
  | Semantic => "semantic"
  | Document => "document"
  | Temporal => "temporal"
  }
}

let modalityFromString = (s: string): option<modalityType> => {
  switch s {
  | "graph" => Some(Graph)
  | "vector" => Some(Vector)
  | "tensor" => Some(Tensor)
  | "semantic" => Some(Semantic)
  | "document" => Some(Document)
  | "temporal" => Some(Temporal)
  | _ => None
  }
}

let serializeRegistry = (registry: registryState): Js.Json.t => {
  // Convert registry to JSON for persistence
  Js.Json.null
}

let deserializeRegistry = (json: Js.Json.t): option<registryState> => {
  // Restore registry from JSON
  None
}

// ============================================================================
// Public API
// ============================================================================

let create = createRegistry
let register = registerStore
let map = mapHexad
let lookup = getHexadLocations
let selectStore = selectBestStore
let updateHealth = updateStoreHealth
let prune = pruneDeadStores
let query = executeFederatedQuery
let replicate = replicateHexad
let consensus = achieveConsensus
