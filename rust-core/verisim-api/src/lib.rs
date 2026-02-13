// SPDX-License-Identifier: PMPL-1.0-or-later
//! VeriSim API
//!
//! HTTP API server for VeriSimDB.
//! Exposes all database functionality via REST endpoints.

pub mod federation;
pub mod graphql;
pub mod grpc;

use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    response::IntoResponse,
    routing::{delete, get, post, put},
    Json, Router,
};
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use thiserror::Error;
use tokio::net::TcpListener;
use tracing::{error, info, instrument};

use std::sync::Mutex;

use verisim_document::TantivyDocumentStore;
use verisim_drift::{DriftDetector, DriftMetrics, DriftThresholds, DriftType};
use verisim_graph::OxiGraphStore;
use verisim_planner::{
    ExplainOutput, LogicalPlan, PhysicalPlan, Planner,
    PlannerConfig, StatisticsCollector,
};
use verisim_hexad::{
    HexadConfig, HexadDocumentInput, HexadGraphInput, HexadId, HexadInput,
    HexadSemanticInput, HexadSnapshot, HexadStore, HexadTensorInput,
    HexadVectorInput, InMemoryHexadStore,
};
use verisim_normalizer::{create_default_normalizer, Normalizer, NormalizerStatus};
use verisim_semantic::InMemorySemanticStore;
use verisim_temporal::InMemoryVersionStore;
use verisim_tensor::InMemoryTensorStore;
use verisim_vector::{DistanceMetric, BruteForceVectorStore};

/// Type alias for our concrete HexadStore implementation
pub type ConcreteHexadStore = InMemoryHexadStore<
    OxiGraphStore,
    BruteForceVectorStore,
    TantivyDocumentStore,
    InMemoryTensorStore,
    InMemorySemanticStore,
    InMemoryVersionStore<HexadSnapshot>,
>;

/// API errors
#[derive(Error, Debug)]
pub enum ApiError {
    #[error("Not found: {0}")]
    NotFound(String),

    #[error("Bad request: {0}")]
    BadRequest(String),

    #[error("Internal error: {0}")]
    Internal(String),

    #[error("Serialization error: {0}")]
    Serialization(String),
}

impl IntoResponse for ApiError {
    fn into_response(self) -> axum::response::Response {
        let (status, client_message) = match &self {
            ApiError::NotFound(msg) => (StatusCode::NOT_FOUND, msg.clone()),
            ApiError::BadRequest(msg) => (StatusCode::BAD_REQUEST, msg.clone()),
            ApiError::Internal(msg) => {
                error!(error = %msg, "Internal server error");
                (StatusCode::INTERNAL_SERVER_ERROR, "Internal server error".to_string())
            }
            ApiError::Serialization(msg) => {
                error!(error = %msg, "Serialization error");
                (StatusCode::INTERNAL_SERVER_ERROR, "Internal server error".to_string())
            }
        };

        let body = Json(ErrorResponse {
            error: client_message,
            code: status.as_u16(),
        });

        (status, body).into_response()
    }
}

/// Error response body
#[derive(Debug, Serialize, Deserialize)]
pub struct ErrorResponse {
    pub error: String,
    pub code: u16,
}

/// API configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ApiConfig {
    /// Host to bind to
    pub host: String,
    /// Port to bind to
    pub port: u16,
    /// Enable CORS
    pub enable_cors: bool,
    /// API version prefix
    pub version_prefix: String,
    /// Vector dimension for embeddings
    pub vector_dimension: usize,
}

impl Default for ApiConfig {
    fn default() -> Self {
        Self {
            host: "[::1]".to_string(),
            port: 8080,
            enable_cors: true,
            version_prefix: "/api/v1".to_string(),
            vector_dimension: 384,
        }
    }
}

/// Maximum number of results allowed in any search/list endpoint.
const MAX_RESULT_LIMIT: usize = 1000;

/// Validate and cap a limit parameter.
fn validate_limit(limit: usize) -> usize {
    limit.min(MAX_RESULT_LIMIT)
}

/// Validate a hexad ID: max 128 chars, alphanumeric + dash + underscore only.
fn validate_hexad_id(id: &str) -> Result<(), ApiError> {
    if id.is_empty() {
        return Err(ApiError::BadRequest("Hexad ID must not be empty".to_string()));
    }
    if id.len() > 128 {
        return Err(ApiError::BadRequest("Hexad ID must be at most 128 characters".to_string()));
    }
    if !id.chars().all(|c| c.is_alphanumeric() || c == '-' || c == '_') {
        return Err(ApiError::BadRequest(
            "Hexad ID must contain only alphanumeric characters, dashes, and underscores".to_string(),
        ));
    }
    Ok(())
}

/// Validate that all vector components are finite (no NaN/Inf).
fn validate_vector(v: &[f32]) -> Result<(), ApiError> {
    if !v.iter().all(|x| x.is_finite()) {
        return Err(ApiError::BadRequest(
            "Vector contains NaN or Inf values".to_string(),
        ));
    }
    Ok(())
}

/// Health check response
#[derive(Debug, Serialize, Deserialize)]
pub struct HealthResponse {
    pub status: String,
    pub version: String,
    pub uptime_seconds: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub degraded_reason: Option<String>,
}

/// Hexad create/update request
#[derive(Debug, Serialize, Deserialize)]
pub struct HexadRequest {
    /// Document title
    pub title: Option<String>,
    /// Document body
    pub body: Option<String>,
    /// Vector embedding
    pub embedding: Option<Vec<f32>>,
    /// Semantic types
    pub types: Option<Vec<String>>,
    /// Relationships (predicate, target_id)
    pub relationships: Option<Vec<(String, String)>>,
    /// Tensor data
    pub tensor: Option<TensorRequest>,
    /// Metadata
    pub metadata: Option<std::collections::HashMap<String, String>>,
}

impl HexadRequest {
    /// Convert to HexadInput
    fn to_hexad_input(&self) -> HexadInput {
        let mut input = HexadInput::default();

        if let (Some(title), Some(body)) = (&self.title, &self.body) {
            input.document = Some(HexadDocumentInput {
                title: title.clone(),
                body: body.clone(),
                fields: std::collections::HashMap::new(),
            });
        } else if let Some(title) = &self.title {
            input.document = Some(HexadDocumentInput {
                title: title.clone(),
                body: String::new(),
                fields: std::collections::HashMap::new(),
            });
        }

        if let Some(embedding) = &self.embedding {
            input.vector = Some(HexadVectorInput {
                embedding: embedding.clone(),
                model: None,
            });
        }

        if let Some(types) = &self.types {
            input.semantic = Some(HexadSemanticInput {
                types: types.clone(),
                properties: std::collections::HashMap::new(),
            });
        }

        if let Some(relationships) = &self.relationships {
            input.graph = Some(HexadGraphInput {
                relationships: relationships.clone(),
            });
        }

        if let Some(tensor) = &self.tensor {
            input.tensor = Some(HexadTensorInput {
                shape: tensor.shape.clone(),
                data: tensor.data.clone(),
            });
        }

        if let Some(metadata) = &self.metadata {
            input.metadata = metadata.clone();
        }

        input
    }
}

/// Tensor data in request
#[derive(Debug, Serialize, Deserialize)]
pub struct TensorRequest {
    pub shape: Vec<usize>,
    pub data: Vec<f64>,
}

/// Hexad response
#[derive(Debug, Serialize, Deserialize)]
pub struct HexadResponse {
    pub id: String,
    pub status: HexadStatusResponse,
    pub has_graph: bool,
    pub has_vector: bool,
    pub has_tensor: bool,
    pub has_semantic: bool,
    pub has_document: bool,
    pub version_count: u64,
}

/// Status response
#[derive(Debug, Serialize, Deserialize)]
pub struct HexadStatusResponse {
    pub created_at: String,
    pub modified_at: String,
    pub version: u64,
}

impl From<&verisim_hexad::Hexad> for HexadResponse {
    fn from(h: &verisim_hexad::Hexad) -> Self {
        Self {
            id: h.id.to_string(),
            status: HexadStatusResponse {
                created_at: h.status.created_at.to_rfc3339(),
                modified_at: h.status.modified_at.to_rfc3339(),
                version: h.status.version,
            },
            has_graph: h.graph_node.is_some(),
            has_vector: h.embedding.is_some(),
            has_tensor: h.tensor.is_some(),
            has_semantic: h.semantic.is_some(),
            has_document: h.document.is_some(),
            version_count: h.version_count,
        }
    }
}

/// Pagination query parameters for list endpoints
#[derive(Debug, Deserialize)]
pub struct ListQuery {
    /// Maximum number of results (default 100, max 1000)
    pub limit: Option<usize>,
    /// Offset for pagination (default 0)
    pub offset: Option<usize>,
}

/// Search query parameters
#[derive(Debug, Deserialize)]
pub struct SearchQuery {
    /// Text query for document search
    pub q: Option<String>,
    /// Number of results
    pub limit: Option<usize>,
}

/// Vector search request
#[derive(Debug, Serialize, Deserialize)]
pub struct VectorSearchRequest {
    /// Query vector
    pub vector: Vec<f32>,
    /// Number of results
    pub k: Option<usize>,
}

/// Search result
#[derive(Debug, Serialize, Deserialize)]
pub struct SearchResultResponse {
    pub id: String,
    pub score: f32,
    pub title: Option<String>,
}

/// Drift status response
#[derive(Debug, Serialize, Deserialize)]
pub struct DriftStatusResponse {
    pub drift_type: String,
    pub current_score: f64,
    pub moving_average: f64,
    pub max_score: f64,
    pub measurement_count: u64,
}

impl DriftStatusResponse {
    fn from_metrics(drift_type: DriftType, metrics: &DriftMetrics) -> Self {
        Self {
            drift_type: drift_type.to_string(),
            current_score: metrics.current_score,
            moving_average: metrics.moving_average,
            max_score: metrics.max_score,
            measurement_count: metrics.measurement_count,
        }
    }
}

/// Application state
#[derive(Clone)]
pub struct AppState {
    pub start_time: std::time::Instant,
    pub hexad_store: Arc<ConcreteHexadStore>,
    pub drift_detector: Arc<DriftDetector>,
    pub normalizer: Arc<Normalizer>,
    pub planner: Arc<Mutex<Planner>>,
    pub federation: federation::FederationState,
    pub config: ApiConfig,
}

impl AppState {
    /// Create new application state with default configuration (async version)
    pub async fn new_async(config: ApiConfig) -> Result<Self, ApiError> {
        let hexad_config = HexadConfig {
            vector_dimension: config.vector_dimension,
            ..Default::default()
        };

        let graph = Arc::new(
            OxiGraphStore::in_memory().map_err(|e| ApiError::Internal(e.to_string()))?,
        );
        let vector = Arc::new(BruteForceVectorStore::new(
            config.vector_dimension,
            DistanceMetric::Cosine,
        ));
        let document = Arc::new(
            TantivyDocumentStore::in_memory().map_err(|e| ApiError::Internal(e.to_string()))?,
        );
        let tensor = Arc::new(InMemoryTensorStore::new());
        let semantic = Arc::new(InMemorySemanticStore::new());
        let temporal = Arc::new(InMemoryVersionStore::new());

        let hexad_store = Arc::new(InMemoryHexadStore::new(
            hexad_config,
            graph,
            vector,
            document,
            tensor,
            semantic,
            temporal,
        ));

        let drift_detector = Arc::new(DriftDetector::new(DriftThresholds::default()));
        let normalizer = Arc::new(create_default_normalizer(drift_detector.clone()).await);

        let planner = Arc::new(Mutex::new(Planner::new(PlannerConfig::default())));

        let self_endpoint = format!("http://{}:{}{}", config.host, config.port, config.version_prefix);
        let federation = federation::FederationState::new(
            "self".to_string(),
            self_endpoint,
        );

        Ok(Self {
            start_time: std::time::Instant::now(),
            hexad_store,
            drift_detector,
            normalizer,
            planner,
            federation,
            config,
        })
    }
}

/// Build the API router
pub fn build_router(state: AppState) -> Router {
    let federation_routes = federation::federation_router(state.federation.clone());

    Router::new()
        // Health endpoints
        .route("/health", get(health_handler))
        .route("/ready", get(ready_handler))
        .route("/metrics", get(metrics_handler))
        // Hexad CRUD
        .route("/hexads", get(list_hexads_handler).post(create_hexad_handler))
        .route("/hexads/{id}", get(get_hexad_handler))
        .route("/hexads/{id}", put(update_hexad_handler))
        .route("/hexads/{id}", delete(delete_hexad_handler))
        // Search endpoints
        .route("/search/text", get(text_search_handler))
        .route("/search/vector", post(vector_search_handler))
        .route("/search/related/{id}", get(related_search_handler))
        // Drift and normalization
        .route("/drift/status", get(drift_status_handler))
        .route("/drift/entity/{id}", get(entity_drift_handler))
        .route("/normalizer/status", get(normalizer_status_handler))
        .route("/normalizer/trigger/{id}", post(trigger_normalization_handler))
        // Query planner
        .route("/query/plan", post(query_plan_handler))
        .route("/query/explain", post(query_explain_handler))
        .route("/planner/config", get(get_planner_config_handler))
        .route("/planner/config", put(put_planner_config_handler))
        .route("/planner/stats", get(planner_stats_handler))
        .with_state(state.clone())
        // GraphQL endpoint
        .merge(graphql::graphql_router(state))
        // Federation endpoints (separate state)
        .merge(federation_routes)
}

/// Health check handler — verifies drift detector status and reports degraded when critical
#[instrument(skip(state))]
async fn health_handler(State(state): State<AppState>) -> (StatusCode, Json<HealthResponse>) {
    let uptime = state.start_time.elapsed().as_secs();
    let version = env!("CARGO_PKG_VERSION").to_string();

    // Check drift detector health
    match state.drift_detector.health_check() {
        Ok(health) => {
            use verisim_drift::HealthStatus;
            let (status_str, reason) = match health.status {
                HealthStatus::Critical => (
                    "degraded",
                    Some(format!(
                        "Critical drift on {:?}: score {:.3}",
                        health.worst_drift_type, health.worst_score
                    )),
                ),
                HealthStatus::Degraded => (
                    "degraded",
                    Some(format!(
                        "Degraded drift on {:?}: score {:.3}",
                        health.worst_drift_type, health.worst_score
                    )),
                ),
                HealthStatus::Warning => ("healthy", None),
                HealthStatus::Healthy => ("healthy", None),
            };

            (
                StatusCode::OK,
                Json(HealthResponse {
                    status: status_str.to_string(),
                    version,
                    uptime_seconds: uptime,
                    degraded_reason: reason,
                }),
            )
        }
        Err(_) => (
            StatusCode::OK,
            Json(HealthResponse {
                status: "degraded".to_string(),
                version,
                uptime_seconds: uptime,
                degraded_reason: Some("Drift detector unavailable".to_string()),
            }),
        ),
    }
}

/// Prometheus metrics handler — exposes drift and query metrics for scraping
#[instrument(skip(state))]
async fn metrics_handler(
    State(state): State<AppState>,
) -> Result<(StatusCode, [(axum::http::header::HeaderName, &'static str); 1], String), ApiError> {
    use prometheus::{Encoder, TextEncoder, GaugeVec, Opts, Registry};

    let registry = Registry::new();

    // Drift gauges
    let drift_gauge = GaugeVec::new(
        Opts::new("verisimdb_drift_score", "Current drift score by type"),
        &["drift_type"],
    )
    .map_err(|e| ApiError::Internal(e.to_string()))?;

    let drift_avg_gauge = GaugeVec::new(
        Opts::new("verisimdb_drift_moving_average", "Drift moving average by type"),
        &["drift_type"],
    )
    .map_err(|e| ApiError::Internal(e.to_string()))?;

    let drift_count_gauge = GaugeVec::new(
        Opts::new("verisimdb_drift_measurement_count", "Drift measurement count by type"),
        &["drift_type"],
    )
    .map_err(|e| ApiError::Internal(e.to_string()))?;

    registry.register(Box::new(drift_gauge.clone())).map_err(|e| ApiError::Internal(e.to_string()))?;
    registry.register(Box::new(drift_avg_gauge.clone())).map_err(|e| ApiError::Internal(e.to_string()))?;
    registry.register(Box::new(drift_count_gauge.clone())).map_err(|e| ApiError::Internal(e.to_string()))?;

    // Populate drift metrics
    if let Ok(all_metrics) = state.drift_detector.all_metrics() {
        for (drift_type, metrics) in &all_metrics {
            let label = drift_type.to_string();
            drift_gauge.with_label_values(&[&label]).set(metrics.current_score);
            drift_avg_gauge.with_label_values(&[&label]).set(metrics.moving_average);
            drift_count_gauge.with_label_values(&[&label]).set(metrics.measurement_count as f64);
        }
    }

    // Uptime gauge
    let uptime = prometheus::Gauge::new("verisimdb_uptime_seconds", "Server uptime in seconds")
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    uptime.set(state.start_time.elapsed().as_secs() as f64);
    registry.register(Box::new(uptime)).map_err(|e| ApiError::Internal(e.to_string()))?;

    // Encode
    let encoder = TextEncoder::new();
    let mut buffer = Vec::new();
    encoder.encode(&registry.gather(), &mut buffer)
        .map_err(|e| ApiError::Internal(e.to_string()))?;

    let output = String::from_utf8(buffer)
        .map_err(|e| ApiError::Internal(e.to_string()))?;

    Ok((
        StatusCode::OK,
        [(axum::http::header::CONTENT_TYPE, "text/plain; version=0.0.4; charset=utf-8")],
        output,
    ))
}

/// Readiness check handler — checks hexad store accessibility and drift detector health
#[instrument(skip(state))]
async fn ready_handler(State(state): State<AppState>) -> StatusCode {
    // Check hexad store is accessible (try a list with limit 0)
    if state.hexad_store.list(1, 0).await.is_err() {
        return StatusCode::SERVICE_UNAVAILABLE;
    }

    // Check drift detector is responsive
    if state.drift_detector.health_check().is_err() {
        return StatusCode::SERVICE_UNAVAILABLE;
    }

    StatusCode::OK
}

/// List hexads handler with pagination
#[instrument(skip(state))]
async fn list_hexads_handler(
    State(state): State<AppState>,
    Query(params): Query<ListQuery>,
) -> Result<Json<Vec<HexadResponse>>, ApiError> {
    let limit = validate_limit(params.limit.unwrap_or(100));
    let offset = params.offset.unwrap_or(0);

    let hexads = state
        .hexad_store
        .list(limit, offset)
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;

    let responses: Vec<HexadResponse> = hexads.iter().map(HexadResponse::from).collect();
    Ok(Json(responses))
}

/// Create hexad handler
#[instrument(skip(state, request))]
async fn create_hexad_handler(
    State(state): State<AppState>,
    Json(request): Json<HexadRequest>,
) -> Result<(StatusCode, Json<HexadResponse>), ApiError> {
    let input = request.to_hexad_input();

    let hexad = state
        .hexad_store
        .create(input)
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;

    Ok((StatusCode::CREATED, Json(HexadResponse::from(&hexad))))
}

/// Get hexad handler
#[instrument(skip(state))]
async fn get_hexad_handler(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<HexadResponse>, ApiError> {
    validate_hexad_id(&id)?;
    let hexad_id = HexadId::new(&id);

    let hexad = state
        .hexad_store
        .get(&hexad_id)
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?
        .ok_or_else(|| ApiError::NotFound(format!("Hexad {} not found", id)))?;

    Ok(Json(HexadResponse::from(&hexad)))
}

/// Update hexad handler
#[instrument(skip(state, request))]
async fn update_hexad_handler(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Json(request): Json<HexadRequest>,
) -> Result<Json<HexadResponse>, ApiError> {
    validate_hexad_id(&id)?;
    let hexad_id = HexadId::new(&id);
    let input = request.to_hexad_input();

    let hexad = state
        .hexad_store
        .update(&hexad_id, input)
        .await
        .map_err(|e| match e {
            verisim_hexad::HexadError::NotFound(_) => {
                ApiError::NotFound(format!("Hexad {} not found", id))
            }
            _ => ApiError::Internal(e.to_string()),
        })?;

    Ok(Json(HexadResponse::from(&hexad)))
}

/// Delete hexad handler
#[instrument(skip(state))]
async fn delete_hexad_handler(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<StatusCode, ApiError> {
    validate_hexad_id(&id)?;
    let hexad_id = HexadId::new(&id);

    state
        .hexad_store
        .delete(&hexad_id)
        .await
        .map_err(|e| match e {
            verisim_hexad::HexadError::NotFound(_) => {
                ApiError::NotFound(format!("Hexad {} not found", id))
            }
            _ => ApiError::Internal(e.to_string()),
        })?;

    Ok(StatusCode::NO_CONTENT)
}

/// Text search handler
#[instrument(skip(state))]
async fn text_search_handler(
    State(state): State<AppState>,
    Query(query): Query<SearchQuery>,
) -> Result<Json<Vec<SearchResultResponse>>, ApiError> {
    let q = match query.q {
        Some(q) if !q.is_empty() => q,
        _ => return Err(ApiError::BadRequest("Query parameter 'q' must not be empty".to_string())),
    };
    let limit = validate_limit(query.limit.unwrap_or(10));

    let hexads = state
        .hexad_store
        .search_text(&q, limit)
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;

    let results: Vec<SearchResultResponse> = hexads
        .iter()
        .enumerate()
        .map(|(i, h)| SearchResultResponse {
            id: h.id.to_string(),
            score: 1.0 - (i as f32 * 0.1), // Approximate score based on ranking
            title: h.document.as_ref().map(|d| d.title.clone()),
        })
        .collect();

    Ok(Json(results))
}

/// Vector search handler
#[instrument(skip(state, request))]
async fn vector_search_handler(
    State(state): State<AppState>,
    Json(request): Json<VectorSearchRequest>,
) -> Result<Json<Vec<SearchResultResponse>>, ApiError> {
    let k = validate_limit(request.k.unwrap_or(10));

    if request.vector.len() != state.config.vector_dimension {
        return Err(ApiError::BadRequest(format!(
            "Vector dimension mismatch: expected {}, got {}",
            state.config.vector_dimension,
            request.vector.len()
        )));
    }
    validate_vector(&request.vector)?;

    let hexads = state
        .hexad_store
        .search_similar(&request.vector, k)
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;

    let results: Vec<SearchResultResponse> = hexads
        .iter()
        .enumerate()
        .map(|(i, h)| SearchResultResponse {
            id: h.id.to_string(),
            score: 1.0 - (i as f32 * 0.1), // Approximate score based on ranking
            title: h.document.as_ref().map(|d| d.title.clone()),
        })
        .collect();

    Ok(Json(results))
}

/// Related entities search handler
#[instrument(skip(state))]
async fn related_search_handler(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(query): Query<RelatedQuery>,
) -> Result<Json<Vec<HexadResponse>>, ApiError> {
    validate_hexad_id(&id)?;
    let hexad_id = HexadId::new(&id);
    let predicate = query.predicate.unwrap_or_else(|| "related".to_string());

    let hexads = state
        .hexad_store
        .query_related(&hexad_id, &predicate)
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;

    let responses: Vec<HexadResponse> = hexads.iter().map(HexadResponse::from).collect();

    Ok(Json(responses))
}

/// Query parameters for related search
#[derive(Debug, Deserialize)]
pub struct RelatedQuery {
    pub predicate: Option<String>,
}

/// Drift status handler
#[instrument(skip(state))]
async fn drift_status_handler(
    State(state): State<AppState>,
) -> Result<Json<Vec<DriftStatusResponse>>, ApiError> {
    let all_metrics = state.drift_detector.all_metrics()
        .map_err(|e| ApiError::Internal(e.to_string()))?;

    let responses: Vec<DriftStatusResponse> = all_metrics
        .iter()
        .map(|(drift_type, metrics)| DriftStatusResponse::from_metrics(*drift_type, metrics))
        .collect();

    Ok(Json(responses))
}

/// Entity drift response
#[derive(Debug, Serialize, Deserialize)]
pub struct EntityDriftResponse {
    pub entity_id: String,
    pub score: f64,
    pub drift_type: String,
    pub status: String,
}

/// Entity drift handler — get drift info for a single entity
#[instrument(skip(state))]
async fn entity_drift_handler(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<EntityDriftResponse>, ApiError> {
    validate_hexad_id(&id)?;
    let hexad_id = HexadId::new(&id);

    // Verify hexad exists
    let _hexad = state
        .hexad_store
        .get(&hexad_id)
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?
        .ok_or_else(|| ApiError::NotFound(format!("Hexad {} not found", id)))?;

    // Get aggregate health from drift detector
    let all_metrics = state.drift_detector.all_metrics()
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let (worst_type, worst_score) = all_metrics
        .iter()
        .max_by(|a, b| a.1.current_score.partial_cmp(&b.1.current_score).unwrap_or(std::cmp::Ordering::Equal))
        .map(|(dt, m)| (dt.to_string(), m.current_score))
        .unwrap_or_else(|| ("none".to_string(), 0.0));

    let status = if worst_score >= 0.7 {
        "critical"
    } else if worst_score >= 0.3 {
        "warning"
    } else {
        "healthy"
    };

    Ok(Json(EntityDriftResponse {
        entity_id: id,
        score: worst_score,
        drift_type: worst_type,
        status: status.to_string(),
    }))
}

/// Normalizer status handler
#[instrument(skip(state))]
async fn normalizer_status_handler(
    State(state): State<AppState>,
) -> Result<Json<NormalizerStatus>, ApiError> {
    let status = state.normalizer.status().await;
    Ok(Json(status))
}

/// Trigger normalization handler
#[instrument(skip(state))]
async fn trigger_normalization_handler(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<StatusCode, ApiError> {
    validate_hexad_id(&id)?;
    let hexad_id = HexadId::new(&id);

    // Check if hexad exists
    let _hexad = state
        .hexad_store
        .get(&hexad_id)
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?
        .ok_or_else(|| ApiError::NotFound(format!("Hexad {} not found", id)))?;

    // In a full implementation, this would trigger actual normalization
    // For now, we just verify the hexad exists and return accepted
    info!(id = %id, "Normalization triggered for hexad");

    Ok(StatusCode::ACCEPTED)
}

// --- Query Planner Handlers ---

/// Query plan handler — optimize a logical plan into a physical plan
#[instrument(skip(state, plan))]
async fn query_plan_handler(
    State(state): State<AppState>,
    Json(plan): Json<LogicalPlan>,
) -> Result<Json<PhysicalPlan>, ApiError> {
    let planner = state.planner.lock().map_err(|_| ApiError::Internal("Planner lock poisoned".to_string()))?;
    let physical = planner
        .optimize(&plan)
        .map_err(|e| ApiError::BadRequest(e.to_string()))?;
    Ok(Json(physical))
}

/// Query explain handler — generate EXPLAIN output for a logical plan
#[instrument(skip(state, plan))]
async fn query_explain_handler(
    State(state): State<AppState>,
    Json(plan): Json<LogicalPlan>,
) -> Result<Json<ExplainOutput>, ApiError> {
    let planner = state.planner.lock().map_err(|_| ApiError::Internal("Planner lock poisoned".to_string()))?;
    let explain = planner
        .explain(&plan)
        .map_err(|e| ApiError::BadRequest(e.to_string()))?;
    Ok(Json(explain))
}

/// Get planner configuration
#[instrument(skip(state))]
async fn get_planner_config_handler(
    State(state): State<AppState>,
) -> Result<Json<PlannerConfig>, ApiError> {
    let planner = state.planner.lock().map_err(|_| ApiError::Internal("Planner lock poisoned".to_string()))?;
    Ok(Json(planner.config().clone()))
}

/// Update planner configuration
#[instrument(skip(state, config))]
async fn put_planner_config_handler(
    State(state): State<AppState>,
    Json(config): Json<PlannerConfig>,
) -> Result<Json<PlannerConfig>, ApiError> {
    let mut planner = state.planner.lock().map_err(|_| ApiError::Internal("Planner lock poisoned".to_string()))?;
    planner.set_config(config);
    Ok(Json(planner.config().clone()))
}

/// Planner statistics snapshot
#[instrument(skip(state))]
async fn planner_stats_handler(
    State(state): State<AppState>,
) -> Result<Json<StatisticsCollector>, ApiError> {
    let planner = state.planner.lock().map_err(|_| ApiError::Internal("Planner lock poisoned".to_string()))?;
    Ok(Json(planner.stats().clone()))
}

/// Start the API server (plain HTTP)
pub async fn serve(config: ApiConfig) -> Result<(), std::io::Error> {
    let state = AppState::new_async(config.clone())
        .await
        .map_err(|e| std::io::Error::other(e.to_string()))?;
    let app = build_router(state);

    let addr = format!("{}:{}", config.host, config.port);
    info!("Starting VeriSimDB API server on {}", addr);

    let listener = TcpListener::bind(&addr).await?;
    axum::serve(listener, app).await?;

    Ok(())
}

/// Start the API server with TLS (HTTPS)
pub async fn serve_tls(
    config: ApiConfig,
    cert_path: &str,
    key_path: &str,
) -> Result<(), std::io::Error> {
    use axum_server::tls_rustls::RustlsConfig;

    let state = AppState::new_async(config.clone())
        .await
        .map_err(|e| std::io::Error::other(e.to_string()))?;
    let app = build_router(state);

    let addr = format!("{}:{}", config.host, config.port);
    info!(addr = %addr, cert = %cert_path, "Starting VeriSimDB API server with TLS");

    let tls_config = RustlsConfig::from_pem_file(cert_path, key_path)
        .await
        .map_err(|e| std::io::Error::other(e.to_string()))?;

    let addr: std::net::SocketAddr = addr
        .parse()
        .map_err(|e: std::net::AddrParseError| std::io::Error::other(e.to_string()))?;

    axum_server::bind_rustls(addr, tls_config)
        .serve(app.into_make_service())
        .await?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use axum::http::{Request, StatusCode};
    use tower::ServiceExt;

    async fn create_test_state() -> AppState {
        AppState::new_async(ApiConfig {
            vector_dimension: 3,
            ..Default::default()
        })
        .await
        .unwrap()
    }

    #[tokio::test]
    async fn test_health_endpoint() {
        let state = create_test_state().await;
        let app = build_router(state);

        let response = app
            .oneshot(
                Request::builder()
                    .uri("/health")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn test_ready_endpoint() {
        let state = create_test_state().await;
        let app = build_router(state);

        let response = app
            .oneshot(
                Request::builder()
                    .uri("/ready")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn test_create_and_get_hexad() {
        let state = create_test_state().await;
        let app = build_router(state);

        // Create a hexad
        let create_request = HexadRequest {
            title: Some("Test Document".to_string()),
            body: Some("Test body content".to_string()),
            embedding: Some(vec![0.1, 0.2, 0.3]),
            types: None,
            relationships: None,
            tensor: None,
            metadata: None,
        };

        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/hexads")
                    .header("content-type", "application/json")
                    .body(Body::from(serde_json::to_string(&create_request).unwrap()))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::CREATED);

        // Parse response to get ID
        let body = axum::body::to_bytes(response.into_body(), 1024 * 1024)
            .await
            .unwrap();
        let created: HexadResponse = serde_json::from_slice(&body).unwrap();

        // Get the hexad
        let response = app
            .oneshot(
                Request::builder()
                    .uri(format!("/hexads/{}", created.id))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn test_text_search() {
        let state = create_test_state().await;
        let app = build_router(state);

        // Create a hexad
        let create_request = HexadRequest {
            title: Some("Rust Programming".to_string()),
            body: Some("Rust is a systems programming language".to_string()),
            embedding: Some(vec![0.1, 0.2, 0.3]),
            types: None,
            relationships: None,
            tensor: None,
            metadata: None,
        };

        let _ = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/hexads")
                    .header("content-type", "application/json")
                    .body(Body::from(serde_json::to_string(&create_request).unwrap()))
                    .unwrap(),
            )
            .await
            .unwrap();

        // Search for it
        let response = app
            .oneshot(
                Request::builder()
                    .uri("/search/text?q=Rust&limit=10")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn test_drift_status() {
        let state = create_test_state().await;
        let app = build_router(state);

        let response = app
            .oneshot(
                Request::builder()
                    .uri("/drift/status")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::OK);
    }
}
