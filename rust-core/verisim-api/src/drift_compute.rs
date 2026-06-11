// SPDX-License-Identifier: MPL-2.0
//! Per-entity drift computation.
//!
//! Bridges the modality stores to [`verisim_drift::DriftCalculator`]: reads an
//! entity's actual cross-modal state and produces measured drift scores, which
//! callers record into the shared [`verisim_drift::DriftDetector`].
//!
//! Components that cannot be measured for an entity (missing modality, or —
//! for semantic-vector drift — no type-embedding registry yet) are reported
//! with `computable: false` and are NOT recorded into the detector, so the
//! moving averages only ever reflect real measurements.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use tracing::warn;
use verisim_drift::{DriftCalculator, DriftDetector, DriftType};
use verisim_graph::{GraphObject, GraphStore};
use verisim_octad::Octad;
use verisim_provenance::ProvenanceStore;
use verisim_temporal::TemporalStore;

use crate::ConcreteOctadStore;

/// Maximum number of versions inspected for temporal-consistency drift.
const TEMPORAL_HISTORY_LIMIT: usize = 256;

/// Provenance gap beyond which staleness contributes to drift (30 days).
const PROVENANCE_MAX_GAP_SECONDS: u64 = 30 * 24 * 60 * 60;

/// One measured (or explicitly unmeasurable) drift component for an entity.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DriftComponent {
    pub drift_type: String,
    pub score: f64,
    /// False when the component could not be measured for this entity
    /// (missing modality or missing reference data). Non-computable
    /// components are excluded from detector recording.
    pub computable: bool,
    pub detail: String,
}

/// Full per-entity drift report computed from the entity's live modality data.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EntityDriftReport {
    pub entity_id: String,
    pub overall_score: f64,
    pub primary_drift_type: String,
    pub components: Vec<DriftComponent>,
    pub computed_at: DateTime<Utc>,
}

struct ComponentScores {
    semantic_vector: (f64, bool, String),
    graph_document: (f64, bool, String),
    temporal: (f64, bool, String),
    tensor: (f64, bool, String),
    schema: (f64, bool, String),
    provenance: (f64, bool, String),
    spatial: (f64, bool, String),
}

/// Names of the modalities currently populated on an octad, in the
/// vocabulary used by schema-drift comparison.
pub fn present_modalities(octad: &Octad) -> Vec<&'static str> {
    let mut present = Vec::with_capacity(8);
    if octad.graph_node.is_some() {
        present.push("graph");
    }
    if octad.embedding.is_some() {
        present.push("vector");
    }
    if octad.tensor.is_some() {
        present.push("tensor");
    }
    if octad.semantic.is_some() {
        present.push("semantic");
    }
    if octad.document.is_some() {
        present.push("document");
    }
    if octad.version_count > 0 {
        present.push("temporal");
    }
    if octad.provenance_chain_length > 0 {
        present.push("provenance");
    }
    if octad.spatial_data.is_some() {
        present.push("spatial");
    }
    present
}

/// Compute measured drift for one entity from its live modality data.
///
/// `required_modalities` is the schema baseline to compare against: pass the
/// modalities present *before* an update to detect modality loss, or `None`
/// to baseline against the entity's current shape (no schema drift).
pub async fn compute_entity_drift(
    store: &ConcreteOctadStore,
    octad: &Octad,
    required_modalities: Option<&[&str]>,
) -> EntityDriftReport {
    let calculator = DriftCalculator::default();
    let entity_id = octad.id.0.clone();

    let scores = ComponentScores {
        semantic_vector: semantic_vector_component(),
        graph_document: graph_document_component(store, octad, &calculator).await,
        temporal: temporal_component(store, &entity_id, &calculator).await,
        tensor: tensor_component(octad, &calculator),
        schema: schema_component(octad, required_modalities, &calculator),
        provenance: provenance_component(store, &entity_id, &calculator).await,
        spatial: spatial_component(octad, &calculator),
    };

    let overall_score = calculator.quality_drift_octad(
        scores.semantic_vector.0,
        scores.graph_document.0,
        scores.temporal.0,
        scores.tensor.0,
        scores.schema.0,
        scores.provenance.0,
        scores.spatial.0,
    );
    let primary = calculator.primary_drift_type_octad(
        scores.semantic_vector.0,
        scores.graph_document.0,
        scores.temporal.0,
        scores.tensor.0,
        scores.schema.0,
        scores.provenance.0,
        scores.spatial.0,
    );

    let component =
        |drift_type: DriftType, (score, computable, detail): (f64, bool, String)| DriftComponent {
            drift_type: drift_type.to_string(),
            score,
            computable,
            detail,
        };

    EntityDriftReport {
        entity_id,
        overall_score,
        primary_drift_type: primary.to_string(),
        components: vec![
            component(DriftType::SemanticVectorDrift, scores.semantic_vector),
            component(DriftType::GraphDocumentDrift, scores.graph_document),
            component(DriftType::TemporalConsistencyDrift, scores.temporal),
            component(DriftType::TensorDrift, scores.tensor),
            component(DriftType::SchemaDrift, scores.schema),
            component(DriftType::ProvenanceDrift, scores.provenance),
            component(DriftType::SpatialDrift, scores.spatial),
        ],
        computed_at: Utc::now(),
    }
}

/// Record a computed report into the shared detector (best-effort).
///
/// Only computable components are recorded, plus the overall quality score,
/// so `/drift/status` aggregates reflect real measurements only. Errors are
/// logged, never propagated: drift bookkeeping must not fail a write.
pub async fn record_entity_drift(detector: &DriftDetector, report: &EntityDriftReport) {
    let drift_type_of = |name: &str| -> Option<DriftType> {
        match name {
            "semantic_vector_drift" => Some(DriftType::SemanticVectorDrift),
            "graph_document_drift" => Some(DriftType::GraphDocumentDrift),
            "temporal_consistency_drift" => Some(DriftType::TemporalConsistencyDrift),
            "tensor_drift" => Some(DriftType::TensorDrift),
            "schema_drift" => Some(DriftType::SchemaDrift),
            "provenance_drift" => Some(DriftType::ProvenanceDrift),
            "spatial_drift" => Some(DriftType::SpatialDrift),
            _ => None,
        }
    };

    for c in report.components.iter().filter(|c| c.computable) {
        if let Some(dt) = drift_type_of(&c.drift_type) {
            if let Err(e) = detector
                .record(dt, c.score, vec![report.entity_id.clone()])
                .await
            {
                warn!(entity = %report.entity_id, drift_type = %c.drift_type, error = %e,
                      "failed to record drift measurement");
            }
        }
    }

    if let Err(e) = detector
        .record(
            DriftType::QualityDrift,
            report.overall_score,
            vec![report.entity_id.clone()],
        )
        .await
    {
        warn!(entity = %report.entity_id, error = %e, "failed to record quality drift");
    }
}

fn semantic_vector_component() -> (f64, bool, String) {
    (
        0.0,
        false,
        "not measured: no type-embedding registry configured".to_string(),
    )
}

async fn graph_document_component(
    store: &ConcreteOctadStore,
    octad: &Octad,
    calculator: &DriftCalculator,
) -> (f64, bool, String) {
    let (Some(node), Some(document)) = (&octad.graph_node, &octad.document) else {
        return (
            0.0,
            false,
            "not measured: requires both graph and document modalities".to_string(),
        );
    };

    let edges = match store.graph_store().outgoing(node).await {
        Ok(edges) => edges,
        Err(e) => return (0.0, false, format!("not measured: graph read failed: {e}")),
    };
    if edges.is_empty() {
        return (
            0.0,
            false,
            "not measured: entity has no outgoing graph relationships".to_string(),
        );
    }

    let relationships: Vec<(String, String)> = edges
        .iter()
        .map(|e| {
            let target = match &e.object {
                GraphObject::Node(n) => n.local_name.clone(),
                GraphObject::Literal { value, .. } => value.clone(),
            };
            (e.predicate.local_name.clone(), target)
        })
        .collect();

    // Without entity extraction, the measurable direction is graph -> document:
    // a relationship target the document never mentions is unreflected structure.
    let text = format!("{} {}", document.title, document.body).to_lowercase();
    let document_entities: Vec<String> = relationships
        .iter()
        .map(|(_, target)| target.clone())
        .filter(|target| text.contains(&target.to_lowercase()))
        .collect();

    let score = if document_entities.is_empty() {
        // Limit case the calculator cannot express (it returns 0.0 for an
        // empty entity list): every relationship target is unreflected in
        // the document, which by its own combination formula
        // ((1 - coverage) + extra_graph_ratio) / 2 evaluates to 0.5.
        0.5
    } else {
        calculator.graph_document_drift(&text, &document_entities, &relationships)
    };
    let detail = format!(
        "{}/{} graph relationship targets mentioned in document",
        document_entities.len(),
        relationships.len()
    );
    (score, true, detail)
}

async fn temporal_component(
    store: &ConcreteOctadStore,
    entity_id: &str,
    calculator: &DriftCalculator,
) -> (f64, bool, String) {
    let versions = match store
        .temporal_store()
        .history(entity_id, TEMPORAL_HISTORY_LIMIT)
        .await
    {
        Ok(v) => v,
        Err(e) => {
            return (
                0.0,
                false,
                format!("not measured: temporal read failed: {e}"),
            )
        }
    };
    if versions.is_empty() {
        return (0.0, false, "not measured: no version history".to_string());
    }

    let timestamps: Vec<i64> = versions.iter().map(|v| v.timestamp.timestamp()).collect();
    let hashes: Vec<u64> = versions
        .iter()
        .map(|v| {
            let serialized = serde_json::to_string(&v.data).unwrap_or_default();
            let mut hasher = DefaultHasher::new();
            serialized.hash(&mut hasher);
            hasher.finish()
        })
        .collect();

    let score = calculator.temporal_consistency_drift(&timestamps, &hashes);
    (
        score,
        true,
        format!("{} versions inspected", versions.len()),
    )
}

fn tensor_component(octad: &Octad, calculator: &DriftCalculator) -> (f64, bool, String) {
    let Some(tensor) = &octad.tensor else {
        return (0.0, false, "not measured: no tensor modality".to_string());
    };

    let declared_len: usize = tensor.shape.iter().product();
    // The declared shape is the expectation; a data buffer that does not fill
    // it is the measurable inconsistency.
    let actual_shape: Vec<usize> = if declared_len == tensor.data.len() {
        tensor.shape.clone()
    } else {
        vec![tensor.data.len()]
    };

    let score = calculator.tensor_drift(&tensor.data, &tensor.shape, &actual_shape, None);
    let detail = format!(
        "shape {:?} declares {} elements, data has {}",
        tensor.shape,
        declared_len,
        tensor.data.len()
    );
    (score, true, detail)
}

fn schema_component(
    octad: &Octad,
    required_modalities: Option<&[&str]>,
    calculator: &DriftCalculator,
) -> (f64, bool, String) {
    let present = present_modalities(octad);
    let required: Vec<&str> = match required_modalities {
        Some(req) => req.to_vec(),
        None => present.clone(),
    };

    let score = calculator.schema_drift(&required, &present, 0, 0);
    let missing: Vec<&&str> = required.iter().filter(|m| !present.contains(*m)).collect();
    let detail = if missing.is_empty() {
        format!("all {} required modalities present", required.len())
    } else {
        format!("missing required modalities: {missing:?}")
    };
    (score, true, detail)
}

async fn provenance_component(
    store: &ConcreteOctadStore,
    entity_id: &str,
    calculator: &DriftCalculator,
) -> (f64, bool, String) {
    let provenance = store.provenance_store();

    let chain = match provenance.get_chain(entity_id).await {
        Ok(chain) => chain,
        Err(verisim_provenance::ProvenanceError::NotFound(_)) => {
            return (
                0.0,
                false,
                "not measured: no provenance events recorded".to_string(),
            )
        }
        Err(e) => {
            return (
                0.0,
                false,
                format!("not measured: provenance read failed: {e}"),
            )
        }
    };
    let chain_valid = provenance.verify_chain(entity_id).await.unwrap_or(false);

    let seconds_since_last = chain
        .latest()
        .map(|record| (Utc::now() - record.timestamp).num_seconds().max(0) as u64);

    let score = calculator.provenance_drift(
        chain_valid,
        chain.len(),
        seconds_since_last,
        PROVENANCE_MAX_GAP_SECONDS,
    );
    let detail = format!(
        "chain length {}, integrity {}",
        chain.len(),
        if chain_valid { "verified" } else { "BROKEN" }
    );
    (score, true, detail)
}

fn spatial_component(octad: &Octad, calculator: &DriftCalculator) -> (f64, bool, String) {
    let Some(spatial) = &octad.spatial_data else {
        return (0.0, false, "not measured: no spatial modality".to_string());
    };

    let lat = spatial.coordinates.latitude;
    let lon = spatial.coordinates.longitude;
    let coordinates_valid = lat.is_finite()
        && lon.is_finite()
        && (-90.0..=90.0).contains(&lat)
        && (-180.0..=180.0).contains(&lon);

    // Location mentions are only detectable through the spatial properties the
    // entity itself declares (address, region, ...): check whether any of those
    // strings appear in the document text.
    let doc_text = octad
        .document
        .as_ref()
        .map(|d| format!("{} {}", d.title, d.body).to_lowercase());
    let mentioned = doc_text.as_ref().map(|text| {
        spatial
            .properties
            .values()
            .any(|v| !v.is_empty() && text.contains(&v.to_lowercase()))
    });
    let has_location_mentions = mentioned.unwrap_or(false);
    let coordinate_matches_mentions = has_location_mentions;

    let score = calculator.spatial_drift(
        true,
        has_location_mentions,
        coordinate_matches_mentions,
        coordinates_valid,
    );
    let detail = format!(
        "coordinates ({lat:.4}, {lon:.4}) {}",
        if coordinates_valid {
            "valid"
        } else {
            "INVALID"
        }
    );
    (score, true, detail)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn octad_with(document: bool, tensor_mismatch: Option<bool>) -> Octad {
        use std::collections::HashMap;
        use verisim_document::Document;
        use verisim_octad::{ModalityStatus, OctadId, OctadStatus};
        use verisim_tensor::{DType, Tensor};

        Octad {
            id: OctadId::new("test-entity"),
            status: OctadStatus {
                id: OctadId::new("test-entity"),
                created_at: Utc::now(),
                modified_at: Utc::now(),
                version: 1,
                modality_status: ModalityStatus::default(),
            },
            graph_node: None,
            embedding: None,
            tensor: tensor_mismatch.map(|mismatch| Tensor {
                id: "test-entity".to_string(),
                shape: vec![2, 2],
                dtype: DType::Float64,
                data: if mismatch {
                    vec![1.0, 2.0, 3.0]
                } else {
                    vec![1.0, 2.0, 3.0, 4.0]
                },
                metadata: HashMap::new(),
            }),
            semantic: None,
            document: if document {
                Some(Document::new("test-entity", "Title", "Body"))
            } else {
                None
            },
            version_count: 1,
            provenance_chain_length: 1,
            spatial_data: None,
        }
    }

    #[test]
    fn present_modalities_reflects_populated_fields() {
        let octad = octad_with(true, Some(false));
        let present = present_modalities(&octad);
        assert!(present.contains(&"document"));
        assert!(present.contains(&"tensor"));
        assert!(present.contains(&"temporal"));
        assert!(present.contains(&"provenance"));
        assert!(!present.contains(&"vector"));
        assert!(!present.contains(&"graph"));
    }

    #[test]
    fn schema_drift_detects_dropped_modality() {
        let calculator = DriftCalculator::default();
        let octad = octad_with(false, None);

        // Baseline that previously had a document: dropping it is drift.
        let (score, computable, detail) = schema_component(
            &octad,
            Some(&["document", "temporal", "provenance"]),
            &calculator,
        );
        assert!(computable);
        assert!(
            score > 0.0,
            "dropping a modality must register schema drift"
        );
        assert!(detail.contains("document"));

        // Self-baseline: no drift.
        let (score, _, _) = schema_component(&octad, None, &calculator);
        assert_eq!(score, 0.0);
    }

    #[test]
    fn tensor_drift_detects_shape_data_mismatch() {
        let calculator = DriftCalculator::default();

        let consistent = octad_with(false, Some(false));
        let (score, computable, _) = tensor_component(&consistent, &calculator);
        assert!(computable);
        assert_eq!(score, 0.0);

        let mismatched = octad_with(false, Some(true));
        let (score, computable, _) = tensor_component(&mismatched, &calculator);
        assert!(computable);
        assert!(
            score > 0.0,
            "shape/data mismatch must register tensor drift"
        );
    }

    #[test]
    fn absent_modalities_are_not_computable() {
        let calculator = DriftCalculator::default();
        let octad = octad_with(false, None);

        let (_, computable, _) = tensor_component(&octad, &calculator);
        assert!(!computable);
        let (_, computable, _) = spatial_component(&octad, &calculator);
        assert!(!computable);
        let (_, computable, _) = semantic_vector_component();
        assert!(!computable);
    }
}
