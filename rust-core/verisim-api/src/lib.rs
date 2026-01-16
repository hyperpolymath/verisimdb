// SPDX-License-Identifier: AGPL-3.0-or-later
//! VeriSim API
//!
//! HTTP API server for VeriSimDB.
//! Exposes all database functionality via REST endpoints.

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
use tracing::{info, instrument};

use verisim_hexad::{Hexad, HexadBuilder, HexadId, HexadInput, HexadStatus};
use verisim_normalizer::NormalizerStatus;

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
        let (status, message) = match self {
            ApiError::NotFound(msg) => (StatusCode::NOT_FOUND, msg),
            ApiError::BadRequest(msg) => (StatusCode::BAD_REQUEST, msg),
            ApiError::Internal(msg) => (StatusCode::INTERNAL_SERVER_ERROR, msg),
            ApiError::Serialization(msg) => (StatusCode::INTERNAL_SERVER_ERROR, msg),
        };

        let body = Json(ErrorResponse {
            error: message,
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
}

impl Default for ApiConfig {
    fn default() -> Self {
        Self {
            host: "0.0.0.0".to_string(),
            port: 8080,
            enable_cors: true,
            version_prefix: "/api/v1".to_string(),
        }
    }
}

/// Health check response
#[derive(Debug, Serialize, Deserialize)]
pub struct HealthResponse {
    pub status: String,
    pub version: String,
    pub uptime_seconds: u64,
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
}

/// Status response
#[derive(Debug, Serialize, Deserialize)]
pub struct HexadStatusResponse {
    pub created_at: String,
    pub modified_at: String,
    pub version: u64,
}

impl From<&Hexad> for HexadResponse {
    fn from(h: &Hexad) -> Self {
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
        }
    }
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

/// Application state
#[derive(Clone)]
pub struct AppState {
    pub start_time: std::time::Instant,
    // In a real implementation, these would be actual store instances
    // pub hexad_store: Arc<dyn HexadStore>,
    // pub normalizer: Arc<Normalizer>,
    // pub drift_detector: Arc<DriftDetector>,
}

impl AppState {
    pub fn new() -> Self {
        Self {
            start_time: std::time::Instant::now(),
        }
    }
}

impl Default for AppState {
    fn default() -> Self {
        Self::new()
    }
}

/// Build the API router
pub fn build_router(state: AppState) -> Router {
    Router::new()
        // Health endpoints
        .route("/health", get(health_handler))
        .route("/ready", get(ready_handler))
        // Hexad CRUD
        .route("/hexads", post(create_hexad_handler))
        .route("/hexads/:id", get(get_hexad_handler))
        .route("/hexads/:id", put(update_hexad_handler))
        .route("/hexads/:id", delete(delete_hexad_handler))
        // Search endpoints
        .route("/search/text", get(text_search_handler))
        .route("/search/vector", post(vector_search_handler))
        .route("/search/related/:id", get(related_search_handler))
        // Drift and normalization
        .route("/drift/status", get(drift_status_handler))
        .route("/normalizer/status", get(normalizer_status_handler))
        .route("/normalizer/trigger/:id", post(trigger_normalization_handler))
        .with_state(state)
}

/// Health check handler
#[instrument]
async fn health_handler(State(state): State<AppState>) -> Json<HealthResponse> {
    Json(HealthResponse {
        status: "healthy".to_string(),
        version: env!("CARGO_PKG_VERSION").to_string(),
        uptime_seconds: state.start_time.elapsed().as_secs(),
    })
}

/// Readiness check handler
#[instrument]
async fn ready_handler() -> StatusCode {
    StatusCode::OK
}

/// Create hexad handler
#[instrument(skip(state, request))]
async fn create_hexad_handler(
    State(state): State<AppState>,
    Json(request): Json<HexadRequest>,
) -> Result<Json<HexadResponse>, ApiError> {
    // In a real implementation, this would create a hexad in the store
    let id = HexadId::generate();

    // Build mock response
    let response = HexadResponse {
        id: id.to_string(),
        status: HexadStatusResponse {
            created_at: chrono::Utc::now().to_rfc3339(),
            modified_at: chrono::Utc::now().to_rfc3339(),
            version: 1,
        },
        has_graph: request.relationships.is_some(),
        has_vector: request.embedding.is_some(),
        has_tensor: request.tensor.is_some(),
        has_semantic: request.types.is_some(),
        has_document: request.title.is_some() || request.body.is_some(),
    };

    Ok(Json(response))
}

/// Get hexad handler
#[instrument(skip(state))]
async fn get_hexad_handler(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<HexadResponse>, ApiError> {
    // In a real implementation, this would fetch from the store
    Err(ApiError::NotFound(format!("Hexad {} not found", id)))
}

/// Update hexad handler
#[instrument(skip(state, request))]
async fn update_hexad_handler(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Json(request): Json<HexadRequest>,
) -> Result<Json<HexadResponse>, ApiError> {
    // In a real implementation, this would update the hexad
    Err(ApiError::NotFound(format!("Hexad {} not found", id)))
}

/// Delete hexad handler
#[instrument(skip(state))]
async fn delete_hexad_handler(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<StatusCode, ApiError> {
    // In a real implementation, this would delete the hexad
    Ok(StatusCode::NO_CONTENT)
}

/// Text search handler
#[instrument(skip(state))]
async fn text_search_handler(
    State(state): State<AppState>,
    Query(query): Query<SearchQuery>,
) -> Result<Json<Vec<SearchResultResponse>>, ApiError> {
    let q = query.q.unwrap_or_default();
    let limit = query.limit.unwrap_or(10);

    // In a real implementation, this would search the document store
    Ok(Json(vec![]))
}

/// Vector search handler
#[instrument(skip(state, request))]
async fn vector_search_handler(
    State(state): State<AppState>,
    Json(request): Json<VectorSearchRequest>,
) -> Result<Json<Vec<SearchResultResponse>>, ApiError> {
    let k = request.k.unwrap_or(10);

    // In a real implementation, this would search the vector store
    Ok(Json(vec![]))
}

/// Related entities search handler
#[instrument(skip(state))]
async fn related_search_handler(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<Vec<HexadResponse>>, ApiError> {
    // In a real implementation, this would query the graph store
    Ok(Json(vec![]))
}

/// Drift status handler
#[instrument(skip(state))]
async fn drift_status_handler(
    State(state): State<AppState>,
) -> Result<Json<Vec<DriftStatusResponse>>, ApiError> {
    // In a real implementation, this would get drift metrics
    Ok(Json(vec![]))
}

/// Normalizer status handler
#[instrument(skip(state))]
async fn normalizer_status_handler(
    State(state): State<AppState>,
) -> Result<Json<NormalizerStatus>, ApiError> {
    // In a real implementation, this would get normalizer status
    Ok(Json(NormalizerStatus {
        running: true,
        pending_count: 0,
        active_count: 0,
        completed_count: 0,
        failure_count: 0,
        last_normalization: None,
    }))
}

/// Trigger normalization handler
#[instrument(skip(state))]
async fn trigger_normalization_handler(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<StatusCode, ApiError> {
    // In a real implementation, this would trigger normalization
    Ok(StatusCode::ACCEPTED)
}

/// Start the API server
pub async fn serve(config: ApiConfig) -> Result<(), std::io::Error> {
    let state = AppState::new();
    let app = build_router(state);

    let addr = format!("{}:{}", config.host, config.port);
    info!("Starting VeriSimDB API server on {}", addr);

    let listener = TcpListener::bind(&addr).await?;
    axum::serve(listener, app).await?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use axum::http::{Request, StatusCode};
    use tower::ServiceExt;

    #[tokio::test]
    async fn test_health_endpoint() {
        let state = AppState::new();
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
        let state = AppState::new();
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
}
