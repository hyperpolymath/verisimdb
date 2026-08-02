// SPDX-License-Identifier: MPL-2.0
//! Store-backed modality regeneration.
//!
//! [`StoreRegenerator`] implements the normalizer's [`ModalityRegenerator`]
//! trait against the live octad store: repairs are written back through
//! `OctadStore::update` (so they are WAL-logged, versioned, and recorded in
//! the provenance chain as `normalized` events), and post-repair drift is
//! re-measured from the freshly persisted state via [`crate::drift_compute`].
//!
//! Supported regeneration pairs (v1, all real write-backs):
//!
//! * Graph -> Document: rebuild the document's relations section from the
//!   entity's actual outgoing edges.
//! * Document -> Vector: deterministic feature-hashing embedding of the
//!   document text. This is an honest fallback embedder (no ML model): it
//!   makes vector content reproducibly derived from the document, which is
//!   the consonance property the octad needs.
//! * Document -> Tensor / Vector -> Tensor: tensor derived from the hash
//!   embedding (or existing embedding) as a 1-D feature tensor.
//!
//! Unsupported pairs return an error so the engine reports an honest
//! `Failed` instead of a fake success.

use std::sync::Arc;

use async_trait::async_trait;
use verisim_graph::{GraphObject, GraphStore};
use verisim_normalizer::regeneration::{Modality, ModalityRegenerator};
use verisim_normalizer::NormalizerError;
use verisim_octad::{
    Octad, OctadDocumentInput, OctadId, OctadInput, OctadProvenanceInput, OctadStore,
    OctadTensorInput, OctadVectorInput,
};

use crate::drift_compute;
use crate::ConcreteOctadStore;

/// Marker line that opens the regenerated relations section in a document
/// body. Used to strip a previous section before appending a fresh one, so
/// repeated normalisation stays idempotent.
const RELATIONS_HEADER: &str = "Relations:";

fn fail(entity_id: &OctadId, message: impl Into<String>) -> NormalizerError {
    NormalizerError::NormalizationFailed {
        entity_id: entity_id.to_string(),
        message: message.into(),
    }
}

pub struct StoreRegenerator {
    store: Arc<ConcreteOctadStore>,
    /// Dimension for regenerated embeddings; must match the store's
    /// configured vector dimension or the write-back is rejected.
    vector_dimension: usize,
}

impl StoreRegenerator {
    pub fn new(store: Arc<ConcreteOctadStore>, vector_dimension: usize) -> Self {
        Self {
            store,
            vector_dimension,
        }
    }

    /// Deterministic feature-hashing embedding of `text` (FNV-1a per token,
    /// signed hashing trick, L2-normalised).
    pub fn hash_embedding(text: &str, dimension: usize) -> Vec<f32> {
        let mut vector = vec![0.0f32; dimension.max(1)];
        for token in text
            .to_lowercase()
            .split(|c: char| !c.is_alphanumeric())
            .filter(|t| !t.is_empty())
        {
            let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
            for byte in token.as_bytes() {
                hash ^= u64::from(*byte);
                hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
            }
            let index = (hash % dimension.max(1) as u64) as usize;
            let sign = if (hash >> 63) == 0 { 1.0 } else { -1.0 };
            vector[index] += sign;
        }
        let norm: f32 = vector.iter().map(|v| v * v).sum::<f32>().sqrt();
        if norm > 0.0 {
            for v in &mut vector {
                *v /= norm;
            }
        }
        vector
    }

    /// Rebuild a document body whose relations section reflects the actual
    /// outgoing graph edges.
    fn document_with_relations(original_body: &str, relations: &[(String, String)]) -> String {
        let base = original_body
            .split(RELATIONS_HEADER)
            .next()
            .unwrap_or(original_body)
            .trim_end();
        let listed: Vec<String> = relations
            .iter()
            .map(|(predicate, target)| format!("{predicate} {target}"))
            .collect();
        format!("{base}\n\n{RELATIONS_HEADER} {}.", listed.join("; "))
    }

    async fn outgoing_relations(&self, octad: &Octad) -> Result<Vec<(String, String)>, String> {
        let Some(node) = &octad.graph_node else {
            return Err("entity has no graph node".to_string());
        };
        let edges = self
            .store
            .graph_store()
            .outgoing(node)
            .await
            .map_err(|e| format!("graph read failed: {e}"))?;
        Ok(edges
            .iter()
            .map(|e| {
                let target = match &e.object {
                    GraphObject::Node(n) => n.local_name.clone(),
                    GraphObject::Literal { value, .. } => value.clone(),
                };
                (e.predicate.local_name.clone(), target)
            })
            .collect())
    }

    /// Write one regenerated modality back through the store with a
    /// `normalized` provenance event, so the repair is versioned and audited.
    async fn write_back(
        &self,
        id: &OctadId,
        input: OctadInput,
        description: String,
    ) -> Result<(), NormalizerError> {
        let input = OctadInput {
            provenance: Some(OctadProvenanceInput {
                event_type: "normalized".to_string(),
                actor: "verisim-normalizer".to_string(),
                source: None,
                description,
            }),
            ..input
        };
        self.store
            .update(id, input)
            .await
            .map(|_| ())
            .map_err(|e| fail(id, format!("write-back failed: {e}")))
    }
}

#[async_trait]
impl ModalityRegenerator for StoreRegenerator {
    async fn regenerate_from(
        &self,
        octad: &Octad,
        source: Modality,
        target: Modality,
    ) -> Result<String, NormalizerError> {
        let id = octad.id.clone();
        match (source, target) {
            (Modality::Graph, Modality::Document) => {
                let relations = self
                    .outgoing_relations(octad)
                    .await
                    .map_err(|m| fail(&id, m))?;
                if relations.is_empty() {
                    return Err(fail(
                        &id,
                        "entity has no outgoing graph relationships to regenerate from",
                    ));
                }
                let document = octad
                    .document
                    .as_ref()
                    .ok_or_else(|| fail(&id, "entity has no document to repair"))?;

                let body = Self::document_with_relations(&document.body, &relations);
                let summary = format!(
                    "document body rebuilt with relations section ({} relationships)",
                    relations.len()
                );
                self.write_back(
                    &id,
                    OctadInput {
                        document: Some(OctadDocumentInput {
                            title: document.title.clone(),
                            body,
                            fields: document.fields.clone(),
                        }),
                        ..Default::default()
                    },
                    summary.clone(),
                )
                .await?;
                Ok(summary)
            }

            (Modality::Document, Modality::Vector) => {
                let document = octad
                    .document
                    .as_ref()
                    .ok_or_else(|| fail(&id, "entity has no document"))?;
                let text = format!("{} {}", document.title, document.body);
                let embedding = Self::hash_embedding(&text, self.vector_dimension);
                let summary = format!(
                    "embedding regenerated from document via deterministic feature hashing (dim {})",
                    embedding.len()
                );
                self.write_back(
                    &id,
                    OctadInput {
                        vector: Some(OctadVectorInput {
                            embedding,
                            model: Some("hash-embedding-v1".to_string()),
                        }),
                        ..Default::default()
                    },
                    summary.clone(),
                )
                .await?;
                Ok(summary)
            }

            (Modality::Document, Modality::Tensor) | (Modality::Vector, Modality::Tensor) => {
                let data: Vec<f64> = if source == Modality::Vector {
                    octad
                        .embedding
                        .as_ref()
                        .ok_or_else(|| fail(&id, "entity has no embedding"))?
                        .vector
                        .iter()
                        .map(|v| f64::from(*v))
                        .collect()
                } else {
                    let document = octad
                        .document
                        .as_ref()
                        .ok_or_else(|| fail(&id, "entity has no document"))?;
                    let text = format!("{} {}", document.title, document.body);
                    Self::hash_embedding(&text, self.vector_dimension)
                        .iter()
                        .map(|v| f64::from(*v))
                        .collect()
                };
                let shape = vec![data.len()];
                let summary = format!(
                    "tensor regenerated from {source} as 1-D feature tensor (len {})",
                    data.len()
                );
                self.write_back(
                    &id,
                    OctadInput {
                        tensor: Some(OctadTensorInput { shape, data }),
                        ..Default::default()
                    },
                    summary.clone(),
                )
                .await?;
                Ok(summary)
            }

            (source, target) => Err(fail(
                &id,
                format!("no regeneration path implemented for {source} -> {target}"),
            )),
        }
    }

    async fn merge_into(
        &self,
        octad: &Octad,
        _sources: &[(Modality, f64)],
        target: Modality,
    ) -> Result<String, NormalizerError> {
        Err(fail(
            &octad.id,
            format!("merge regeneration into {target} is not implemented"),
        ))
    }

    /// Re-measure drift for `modality` from the freshly persisted entity
    /// state (the octad handed in by the engine predates the write-back).
    async fn measure_drift(
        &self,
        octad: &Octad,
        modality: Modality,
    ) -> Result<f64, NormalizerError> {
        let fresh = self
            .store
            .get(&octad.id)
            .await
            .map_err(|e| fail(&octad.id, format!("re-read failed: {e}")))?
            .ok_or_else(|| fail(&octad.id, "entity vanished during normalization"))?;

        let report = drift_compute::compute_entity_drift(&self.store, &fresh, None).await;
        Ok(drift_score_for_modality(&report, modality))
    }
}

/// Map a normalizer modality onto the drift component that measures it.
///
/// Graph/document consonance is one shared component; vector maps to the
/// semantic-vector component (0.0 while that component is unmeasurable);
/// modalities without a dedicated component fall back to the overall score.
pub fn drift_score_for_modality(
    report: &drift_compute::EntityDriftReport,
    modality: Modality,
) -> f64 {
    let component_score = |name: &str| {
        report
            .components
            .iter()
            .find(|c| c.drift_type == name)
            .map(|c| c.score)
    };

    match modality {
        Modality::Document | Modality::Graph => component_score("graph_document_drift"),
        Modality::Vector => component_score("semantic_vector_drift"),
        Modality::Tensor => component_score("tensor_drift"),
        Modality::Temporal => component_score("temporal_consistency_drift"),
        Modality::Provenance => component_score("provenance_drift"),
        Modality::Spatial => component_score("spatial_drift"),
        Modality::Semantic => component_score("schema_drift"),
    }
    .unwrap_or(report.overall_score)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hash_embedding_is_deterministic_and_normalised() {
        let a = StoreRegenerator::hash_embedding("the quick brown fox", 8);
        let b = StoreRegenerator::hash_embedding("the quick brown fox", 8);
        assert_eq!(a, b);
        assert_eq!(a.len(), 8);
        let norm: f32 = a.iter().map(|v| v * v).sum::<f32>().sqrt();
        assert!((norm - 1.0).abs() < 1e-5);

        let c = StoreRegenerator::hash_embedding("a completely different text", 8);
        assert_ne!(a, c, "different text must hash to a different embedding");
    }

    #[test]
    fn document_with_relations_is_idempotent() {
        let relations = vec![("relates_to".to_string(), "orphan-target".to_string())];
        let once = StoreRegenerator::document_with_relations("Original body", &relations);
        assert!(once.contains("Original body"));
        assert!(once.contains("orphan-target"));

        let twice = StoreRegenerator::document_with_relations(&once, &relations);
        assert_eq!(
            twice.matches("orphan-target").count(),
            1,
            "re-normalising must not stack relations sections"
        );
    }
}
