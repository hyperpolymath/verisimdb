// SPDX-License-Identifier: PMPL-1.0-or-later
//! VeriSim Normalizer
//!
//! Self-normalization engine that maintains cross-modal consistency.
//! When drift is detected, the normalizer orchestrates repairs.

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::Arc;
use thiserror::Error;
use tokio::sync::{mpsc, RwLock};

use verisim_drift::{DriftDetector, DriftEvent, DriftType};
use verisim_hexad::{Hexad, HexadId, HexadStore};

/// Normalizer errors
#[derive(Error, Debug)]
pub enum NormalizerError {
    #[error("Normalization failed for {entity_id}: {message}")]
    NormalizationFailed { entity_id: String, message: String },

    #[error("Strategy not found: {0}")]
    StrategyNotFound(String),

    #[error("Hexad error: {0}")]
    HexadError(String),

    #[error("Channel error: {0}")]
    ChannelError(String),
}

/// Result of a normalization operation
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NormalizationResult {
    /// Entity that was normalized
    pub entity_id: HexadId,
    /// Type of normalization performed
    pub normalization_type: NormalizationType,
    /// Whether normalization succeeded
    pub success: bool,
    /// Changes made
    pub changes: Vec<NormalizationChange>,
    /// Duration of normalization
    pub duration_ms: u64,
    /// When normalization completed
    pub completed_at: DateTime<Utc>,
}

/// Types of normalization
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub enum NormalizationType {
    /// Regenerate vector embedding from semantic content
    VectorRegeneration,
    /// Update graph from document analysis
    GraphReconstruction,
    /// Repair temporal consistency
    TemporalRepair,
    /// Synchronize tensor representation
    TensorSync,
    /// Full cross-modal reconciliation
    FullReconciliation,
}

/// A specific change made during normalization
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NormalizationChange {
    /// Modality affected
    pub modality: String,
    /// Field changed
    pub field: String,
    /// Previous value (if available)
    pub old_value: Option<String>,
    /// New value
    pub new_value: String,
    /// Reason for change
    pub reason: String,
}

/// Normalization strategy trait
#[async_trait]
pub trait NormalizationStrategy: Send + Sync {
    /// Get strategy name
    fn name(&self) -> &str;

    /// Check if this strategy applies to a drift type
    fn applies_to(&self, drift_type: DriftType) -> bool;

    /// Perform normalization
    async fn normalize(
        &self,
        hexad: &Hexad,
        drift_event: &DriftEvent,
    ) -> Result<NormalizationResult, NormalizerError>;
}

/// Configuration for the normalizer
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NormalizerConfig {
    /// Whether to auto-normalize on drift detection
    pub auto_normalize: bool,
    /// Maximum concurrent normalizations
    pub max_concurrent: usize,
    /// Minimum drift score to trigger normalization
    pub min_score: f64,
    /// Backoff after failed normalization (seconds)
    pub failure_backoff_secs: u64,
}

impl Default for NormalizerConfig {
    fn default() -> Self {
        Self {
            auto_normalize: true,
            max_concurrent: 10,
            min_score: 0.3,
            failure_backoff_secs: 60,
        }
    }
}

/// Status of the normalizer
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NormalizerStatus {
    /// Whether normalizer is running
    pub running: bool,
    /// Number of pending normalizations
    pub pending_count: usize,
    /// Number of active normalizations
    pub active_count: usize,
    /// Total normalizations completed
    pub completed_count: u64,
    /// Total failures
    pub failure_count: u64,
    /// Last normalization time
    pub last_normalization: Option<DateTime<Utc>>,
}

/// The main normalizer engine
pub struct Normalizer {
    config: NormalizerConfig,
    strategies: Arc<RwLock<Vec<Arc<dyn NormalizationStrategy>>>>,
    drift_detector: Arc<DriftDetector>,
    status: Arc<RwLock<NormalizerStatus>>,
    result_sender: Option<mpsc::Sender<NormalizationResult>>,
}

impl Normalizer {
    /// Create a new normalizer
    pub fn new(config: NormalizerConfig, drift_detector: Arc<DriftDetector>) -> Self {
        Self {
            config,
            strategies: Arc::new(RwLock::new(Vec::new())),
            drift_detector,
            status: Arc::new(RwLock::new(NormalizerStatus {
                running: false,
                pending_count: 0,
                active_count: 0,
                completed_count: 0,
                failure_count: 0,
                last_normalization: None,
            })),
            result_sender: None,
        }
    }

    /// Create with default config
    pub fn with_defaults(drift_detector: Arc<DriftDetector>) -> Self {
        Self::new(NormalizerConfig::default(), drift_detector)
    }

    /// Set result notification channel
    pub fn with_result_channel(mut self, sender: mpsc::Sender<NormalizationResult>) -> Self {
        self.result_sender = Some(sender);
        self
    }

    /// Register a normalization strategy
    pub async fn register_strategy(&self, strategy: Arc<dyn NormalizationStrategy>) {
        self.strategies.write().await.push(strategy);
    }

    /// Handle a drift event
    pub async fn handle_drift(
        &self,
        hexad: &Hexad,
        event: &DriftEvent,
    ) -> Result<Option<NormalizationResult>, NormalizerError> {
        if event.score < self.config.min_score {
            return Ok(None);
        }

        // Find applicable strategy
        let strategies = self.strategies.read().await;
        let strategy = strategies
            .iter()
            .find(|s| s.applies_to(event.drift_type))
            .cloned();

        let strategy = match strategy {
            Some(s) => s,
            None => return Ok(None),
        };

        // Update status
        {
            let mut status = self.status.write().await;
            status.active_count += 1;
        }

        // Perform normalization
        let start = std::time::Instant::now();
        let result = strategy.normalize(hexad, event).await;

        // Update status
        {
            let mut status = self.status.write().await;
            status.active_count -= 1;
            match &result {
                Ok(_) => {
                    status.completed_count += 1;
                    status.last_normalization = Some(Utc::now());
                }
                Err(_) => {
                    status.failure_count += 1;
                }
            }
        }

        let result = result?;

        // Send notification
        if let Some(ref sender) = self.result_sender {
            sender
                .send(result.clone())
                .await
                .map_err(|e| NormalizerError::ChannelError(e.to_string()))?;
        }

        Ok(Some(result))
    }

    /// Get current status
    pub async fn status(&self) -> NormalizerStatus {
        self.status.read().await.clone()
    }

    /// Get registered strategies
    pub async fn strategies(&self) -> Vec<String> {
        self.strategies
            .read()
            .await
            .iter()
            .map(|s| s.name().to_string())
            .collect()
    }
}

/// Default strategy for semantic-vector drift
pub struct SemanticVectorStrategy;

#[async_trait]
impl NormalizationStrategy for SemanticVectorStrategy {
    fn name(&self) -> &str {
        "semantic-vector-sync"
    }

    fn applies_to(&self, drift_type: DriftType) -> bool {
        matches!(drift_type, DriftType::SemanticVectorDrift)
    }

    async fn normalize(
        &self,
        hexad: &Hexad,
        _drift_event: &DriftEvent,
    ) -> Result<NormalizationResult, NormalizerError> {
        // In a real implementation, this would:
        // 1. Extract semantic content from the hexad
        // 2. Generate a new embedding
        // 3. Update the vector store

        let changes = vec![NormalizationChange {
            modality: "vector".to_string(),
            field: "embedding".to_string(),
            old_value: None,
            new_value: "[regenerated]".to_string(),
            reason: "Semantic-vector drift detected".to_string(),
        }];

        Ok(NormalizationResult {
            entity_id: hexad.id.clone(),
            normalization_type: NormalizationType::VectorRegeneration,
            success: true,
            changes,
            duration_ms: 0,
            completed_at: Utc::now(),
        })
    }
}

/// Default strategy for graph-document drift
pub struct GraphDocumentStrategy;

#[async_trait]
impl NormalizationStrategy for GraphDocumentStrategy {
    fn name(&self) -> &str {
        "graph-document-sync"
    }

    fn applies_to(&self, drift_type: DriftType) -> bool {
        matches!(drift_type, DriftType::GraphDocumentDrift)
    }

    async fn normalize(
        &self,
        hexad: &Hexad,
        _drift_event: &DriftEvent,
    ) -> Result<NormalizationResult, NormalizerError> {
        // In a real implementation, this would:
        // 1. Analyze document content for entities/relationships
        // 2. Compare with existing graph structure
        // 3. Update graph to match document

        let changes = vec![NormalizationChange {
            modality: "graph".to_string(),
            field: "relationships".to_string(),
            old_value: None,
            new_value: "[reconstructed from document]".to_string(),
            reason: "Graph-document drift detected".to_string(),
        }];

        Ok(NormalizationResult {
            entity_id: hexad.id.clone(),
            normalization_type: NormalizationType::GraphReconstruction,
            success: true,
            changes,
            duration_ms: 0,
            completed_at: Utc::now(),
        })
    }
}

/// Create a normalizer with default strategies
pub async fn create_default_normalizer(drift_detector: Arc<DriftDetector>) -> Normalizer {
    let normalizer = Normalizer::with_defaults(drift_detector);
    normalizer
        .register_strategy(Arc::new(SemanticVectorStrategy))
        .await;
    normalizer
        .register_strategy(Arc::new(GraphDocumentStrategy))
        .await;
    normalizer
}

#[cfg(test)]
mod tests {
    use super::*;
    use verisim_drift::DriftThresholds;
    use verisim_hexad::{HexadStatus, ModalityStatus};

    fn create_test_hexad() -> Hexad {
        Hexad {
            id: HexadId::new("test-1"),
            status: HexadStatus {
                id: HexadId::new("test-1"),
                created_at: Utc::now(),
                modified_at: Utc::now(),
                version: 1,
                modality_status: ModalityStatus::default(),
            },
            graph_node: None,
            embedding: None,
            tensor: None,
            semantic: None,
            document: None,
            version_count: 1,
        }
    }

    #[tokio::test]
    async fn test_normalizer_with_strategies() {
        let drift_detector = Arc::new(DriftDetector::new(DriftThresholds::default()));
        let normalizer = create_default_normalizer(drift_detector).await;

        let strategies = normalizer.strategies().await;
        assert!(strategies.contains(&"semantic-vector-sync".to_string()));
        assert!(strategies.contains(&"graph-document-sync".to_string()));
    }

    #[tokio::test]
    async fn test_handle_drift() {
        let drift_detector = Arc::new(DriftDetector::new(DriftThresholds::default()));
        let normalizer = create_default_normalizer(drift_detector).await;

        let hexad = create_test_hexad();
        let event = DriftEvent::new(
            DriftType::SemanticVectorDrift,
            0.5,
            "Test drift",
        );

        let result = normalizer.handle_drift(&hexad, &event).await.unwrap();
        assert!(result.is_some());
        assert!(result.unwrap().success);
    }
}
