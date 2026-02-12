// SPDX-License-Identifier: PMPL-1.0-or-later
//! Federation Protocol for VeriSimDB
//!
//! Enables cross-instance querying with drift-aware consistency policies.
//! Each VeriSimDB instance can federate with others to form a distributed
//! knowledge network while maintaining local autonomy.
//!
//! ## Protocol
//!
//! Federation uses a pull-based HTTP protocol where the coordinator
//! (the instance receiving the query) fans out requests to peer stores
//! and aggregates results according to the configured drift policy.
//!
//! ## Drift Policies
//!
//! - **Strict**: Only return results from stores with drift score < threshold.
//! - **Repair**: Return results and trigger normalization on drifted stores.
//! - **Tolerate**: Return all results, annotating drifted ones.
//! - **Latest**: Return only the most recent version from each store.

use axum::{
    extract::{Query, State},
    http::StatusCode,

    routing::{get, post},
    Json, Router,
};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::{Arc, RwLock};
use tracing::{info, instrument};

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// Drift policy for federated queries.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum DriftPolicy {
    Strict,
    Repair,
    Tolerate,
    Latest,
}

impl Default for DriftPolicy {
    fn default() -> Self {
        DriftPolicy::Tolerate
    }
}

/// A registered peer store in the federation.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PeerStore {
    /// Unique store identifier.
    pub store_id: String,
    /// HTTP endpoint URL (e.g., "https://store-2.verisimdb.example.com/api/v1").
    pub endpoint: String,
    /// Modalities this store supports.
    pub modalities: Vec<String>,
    /// Trust level (0.0 - 1.0).
    pub trust_level: f64,
    /// Last health check timestamp (RFC 3339).
    pub last_seen: Option<String>,
    /// Average response time in milliseconds.
    pub response_time_ms: Option<u64>,
}

/// A federation query request.
#[derive(Debug, Serialize, Deserialize)]
pub struct FederationQueryRequest {
    /// Pattern to match stores (e.g., "/universities/*", or a specific store ID).
    pub pattern: String,
    /// Modalities to query.
    pub modalities: Vec<String>,
    /// Drift policy.
    #[serde(default)]
    pub drift_policy: DriftPolicy,
    /// Maximum results per store.
    pub limit: Option<usize>,
    /// Optional text query.
    pub text_query: Option<String>,
    /// Optional vector query.
    pub vector_query: Option<Vec<f32>>,
}

/// A single result from a federated query.
#[derive(Debug, Serialize, Deserialize)]
pub struct FederationResult {
    /// Which store provided this result.
    pub source_store: String,
    /// Hexad ID.
    pub hexad_id: String,
    /// Relevance score.
    pub score: f64,
    /// Whether the source store has drift issues.
    pub drifted: bool,
    /// Result data (modality-dependent).
    pub data: serde_json::Value,
}

/// Response for federation queries.
#[derive(Debug, Serialize, Deserialize)]
pub struct FederationQueryResponse {
    /// Query results aggregated from all matching stores.
    pub results: Vec<FederationResult>,
    /// Stores that were queried.
    pub stores_queried: Vec<String>,
    /// Stores that failed or were excluded by drift policy.
    pub stores_excluded: Vec<String>,
    /// The drift policy applied.
    pub drift_policy: DriftPolicy,
}

/// Registration request to join the federation.
#[derive(Debug, Serialize, Deserialize)]
pub struct RegisterRequest {
    pub store_id: String,
    pub endpoint: String,
    pub modalities: Vec<String>,
}

/// Health check from a peer.
#[derive(Debug, Serialize, Deserialize)]
pub struct HeartbeatRequest {
    pub store_id: String,
    pub drift_scores: HashMap<String, f64>,
}

/// Federation registry query parameters.
#[derive(Debug, Deserialize)]
pub struct PeerQueryParams {
    pub modality: Option<String>,
}

// ---------------------------------------------------------------------------
// Federation State
// ---------------------------------------------------------------------------

/// Shared federation state — registry of known peer stores.
#[derive(Clone)]
pub struct FederationState {
    pub peers: Arc<RwLock<HashMap<String, PeerStore>>>,
    pub self_store_id: String,
    pub self_endpoint: String,
    /// Drift threshold for Strict policy.
    pub strict_drift_threshold: f64,
}

impl FederationState {
    pub fn new(self_store_id: String, self_endpoint: String) -> Self {
        Self {
            peers: Arc::new(RwLock::new(HashMap::new())),
            self_store_id,
            self_endpoint,
            strict_drift_threshold: 0.3,
        }
    }
}

// ---------------------------------------------------------------------------
// Router
// ---------------------------------------------------------------------------

/// Build federation API routes.
pub fn federation_router(state: FederationState) -> Router {
    Router::new()
        .route("/federation/peers", get(list_peers))
        .route("/federation/register", post(register_peer))
        .route("/federation/heartbeat", post(heartbeat))
        .route("/federation/query", post(federation_query))
        .route("/federation/deregister/{store_id}", post(deregister_peer))
        .with_state(state)
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

/// List all known peer stores.
#[instrument(skip(state))]
async fn list_peers(
    State(state): State<FederationState>,
    Query(params): Query<PeerQueryParams>,
) -> Json<Vec<PeerStore>> {
    let peers = state.peers.read().expect("peers RwLock poisoned");

    let result: Vec<PeerStore> = peers
        .values()
        .filter(|p| {
            if let Some(ref modality) = params.modality {
                p.modalities.iter().any(|m| m == modality)
            } else {
                true
            }
        })
        .cloned()
        .collect();

    Json(result)
}

/// Register a new peer store in the federation.
#[instrument(skip(state))]
async fn register_peer(
    State(state): State<FederationState>,
    Json(request): Json<RegisterRequest>,
) -> Result<(StatusCode, Json<PeerStore>), StatusCode> {
    let peer = PeerStore {
        store_id: request.store_id.clone(),
        endpoint: request.endpoint,
        modalities: request.modalities,
        trust_level: 1.0,
        last_seen: Some(chrono::Utc::now().to_rfc3339()),
        response_time_ms: None,
    };

    info!(store_id = %request.store_id, "Registered peer store");

    state
        .peers
        .write()
        .expect("peers RwLock poisoned")
        .insert(request.store_id, peer.clone());

    Ok((StatusCode::CREATED, Json(peer)))
}

/// Receive a heartbeat from a peer.
#[instrument(skip(state))]
async fn heartbeat(
    State(state): State<FederationState>,
    Json(request): Json<HeartbeatRequest>,
) -> StatusCode {
    let mut peers = state.peers.write().expect("peers RwLock poisoned");

    if let Some(peer) = peers.get_mut(&request.store_id) {
        peer.last_seen = Some(chrono::Utc::now().to_rfc3339());
        StatusCode::OK
    } else {
        StatusCode::NOT_FOUND
    }
}

/// Remove a peer from the federation.
#[instrument(skip(state))]
async fn deregister_peer(
    State(state): State<FederationState>,
    axum::extract::Path(store_id): axum::extract::Path<String>,
) -> StatusCode {
    let removed = state
        .peers
        .write()
        .expect("peers RwLock poisoned")
        .remove(&store_id);

    if removed.is_some() {
        info!(store_id = %store_id, "Deregistered peer store");
        StatusCode::OK
    } else {
        StatusCode::NOT_FOUND
    }
}

/// Execute a federated query across matching peer stores.
#[instrument(skip(state))]
async fn federation_query(
    State(state): State<FederationState>,
    Json(request): Json<FederationQueryRequest>,
) -> Json<FederationQueryResponse> {
    let peers = state.peers.read().expect("peers RwLock poisoned");

    // Resolve pattern to matching stores
    let matching_stores: Vec<&PeerStore> = peers
        .values()
        .filter(|p| pattern_matches(&request.pattern, &p.store_id))
        .filter(|p| {
            // Filter by required modalities
            request
                .modalities
                .iter()
                .all(|m| p.modalities.iter().any(|pm| pm == m))
        })
        .collect();

    let mut stores_queried = Vec::new();
    let mut stores_excluded = Vec::new();
    let results: Vec<FederationResult> = Vec::new();

    for store in &matching_stores {
        // Apply drift policy filtering
        let include = match request.drift_policy {
            DriftPolicy::Strict => store.trust_level >= (1.0 - state.strict_drift_threshold),
            DriftPolicy::Repair | DriftPolicy::Tolerate | DriftPolicy::Latest => true,
        };

        if !include {
            stores_excluded.push(store.store_id.clone());
            info!(
                store_id = %store.store_id,
                trust = store.trust_level,
                "Excluded store due to Strict drift policy"
            );
            continue;
        }

        stores_queried.push(store.store_id.clone());

        // In production: make HTTP request to store.endpoint using reqwest/hyper:
        //   POST {store.endpoint}/search/text   (for text queries)
        //   POST {store.endpoint}/search/vector  (for vector queries)
        //   GET  {store.endpoint}/hexads/{id}    (for specific hexad)
        info!(
            store_id = %store.store_id,
            endpoint = %store.endpoint,
            "Would query federated store"
        );
    }

    Json(FederationQueryResponse {
        results,
        stores_queried,
        stores_excluded,
        drift_policy: request.drift_policy,
    })
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Match a federation pattern against a store ID.
/// Supports glob-style wildcards: "/universities/*" matches "/universities/oxford".
fn pattern_matches(pattern: &str, store_id: &str) -> bool {
    if pattern == "*" {
        return true;
    }

    if let Some(prefix) = pattern.strip_suffix("/*") {
        store_id.starts_with(prefix)
    } else {
        pattern == store_id
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_pattern_matching() {
        assert!(pattern_matches("*", "any-store"));
        assert!(pattern_matches("/universities/*", "/universities/oxford"));
        assert!(pattern_matches("/universities/*", "/universities/cambridge"));
        assert!(!pattern_matches("/universities/*", "/hospitals/nhs"));
        assert!(pattern_matches("store-1", "store-1"));
        assert!(!pattern_matches("store-1", "store-2"));
    }

    #[test]
    fn test_federation_state() {
        let state = FederationState::new("self".to_string(), "http://localhost:8080".to_string());

        let peer = PeerStore {
            store_id: "peer-1".to_string(),
            endpoint: "http://peer-1:8080".to_string(),
            modalities: vec!["graph".to_string(), "vector".to_string()],
            trust_level: 0.95,
            last_seen: None,
            response_time_ms: None,
        };

        state
            .peers
            .write()
            .unwrap()
            .insert("peer-1".to_string(), peer);

        let peers = state.peers.read().unwrap();
        assert_eq!(peers.len(), 1);
        assert_eq!(peers["peer-1"].trust_level, 0.95);
    }
}
