// SPDX-License-Identifier: PMPL-1.0-or-later
//! In-memory HexadStore implementation
//!
//! Coordinates all six modality stores for unified entity management.

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::RwLock;
use tracing::{debug, info, instrument};

use crate::{
    Document, DocumentStore, Embedding, GraphEdge, GraphNode, GraphObject, GraphStore, Hexad,
    HexadConfig, HexadDocumentInput, HexadError, HexadGraphInput, HexadId, HexadInput,
    HexadSemanticInput, HexadStatus, HexadStore, HexadTensorInput, HexadVectorInput,
    ModalityStatus, Provenance, SemanticAnnotation, SemanticStore, SemanticValue, Tensor,
    TensorStore, TemporalStore, VectorStore,
};

/// Snapshot of a Hexad for versioning
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HexadSnapshot {
    pub id: HexadId,
    pub input: HexadInput,
    pub modality_status: ModalityStatus,
    pub timestamp: DateTime<Utc>,
}

/// In-memory implementation of HexadStore
///
/// This store coordinates all six modality stores, ensuring cross-modal
/// consistency when entities are created, updated, or deleted.
pub struct InMemoryHexadStore<G, V, D, T, S, R>
where
    G: GraphStore,
    V: VectorStore,
    D: DocumentStore,
    T: TensorStore,
    S: SemanticStore,
    R: TemporalStore<Data = HexadSnapshot>,
{
    config: HexadConfig,
    /// Hexad status registry
    hexads: Arc<RwLock<HashMap<String, HexadStatus>>>,
    /// Graph store
    graph: Arc<G>,
    /// Vector store
    vector: Arc<V>,
    /// Document store
    document: Arc<D>,
    /// Tensor store
    tensor: Arc<T>,
    /// Semantic store
    semantic: Arc<S>,
    /// Temporal (versioning) store
    temporal: Arc<R>,
}

impl<G, V, D, T, S, R> InMemoryHexadStore<G, V, D, T, S, R>
where
    G: GraphStore,
    V: VectorStore,
    D: DocumentStore,
    T: TensorStore,
    S: SemanticStore,
    R: TemporalStore<Data = HexadSnapshot>,
{
    /// Create a new in-memory hexad store
    pub fn new(
        config: HexadConfig,
        graph: Arc<G>,
        vector: Arc<V>,
        document: Arc<D>,
        tensor: Arc<T>,
        semantic: Arc<S>,
        temporal: Arc<R>,
    ) -> Self {
        Self {
            config,
            hexads: Arc::new(RwLock::new(HashMap::new())),
            graph,
            vector,
            document,
            tensor,
            semantic,
            temporal,
        }
    }

    /// Process graph input for a hexad
    async fn process_graph(
        &self,
        id: &HexadId,
        input: &HexadGraphInput,
    ) -> Result<GraphNode, HexadError> {
        let node = GraphNode::new(id.to_iri(&self.config.base_iri));

        for (predicate, target_id) in &input.relationships {
            let edge = GraphEdge {
                subject: node.clone(),
                predicate: GraphNode::new(format!("{}/{}", self.config.base_iri, predicate)),
                object: GraphObject::Node(GraphNode::new(format!(
                    "{}/{}",
                    self.config.base_iri, target_id
                ))),
            };
            self.graph.insert(&edge).await.map_err(|e| HexadError::ModalityError {
                modality: "graph".to_string(),
                message: e.to_string(),
            })?;
        }

        debug!(id = %id, relationships = input.relationships.len(), "Graph modality populated");
        Ok(node)
    }

    /// Process vector input for a hexad
    async fn process_vector(
        &self,
        id: &HexadId,
        input: &HexadVectorInput,
    ) -> Result<Embedding, HexadError> {
        if input.embedding.len() != self.config.vector_dimension {
            return Err(HexadError::ValidationError(format!(
                "Vector dimension mismatch: expected {}, got {}",
                self.config.vector_dimension,
                input.embedding.len()
            )));
        }

        let embedding = Embedding::new(id.as_str(), input.embedding.clone());
        self.vector.upsert(&embedding).await.map_err(|e| HexadError::ModalityError {
            modality: "vector".to_string(),
            message: e.to_string(),
        })?;

        debug!(id = %id, dimension = input.embedding.len(), "Vector modality populated");
        Ok(embedding)
    }

    /// Process document input for a hexad
    async fn process_document(
        &self,
        id: &HexadId,
        input: &HexadDocumentInput,
    ) -> Result<Document, HexadError> {
        let mut doc = Document::new(id.as_str(), &input.title, &input.body);
        for (key, value) in &input.fields {
            doc = doc.with_field(key, value);
        }

        self.document.index(&doc).await.map_err(|e| HexadError::ModalityError {
            modality: "document".to_string(),
            message: e.to_string(),
        })?;
        self.document.commit().await.map_err(|e| HexadError::ModalityError {
            modality: "document".to_string(),
            message: e.to_string(),
        })?;

        debug!(id = %id, title = %input.title, "Document modality populated");
        Ok(doc)
    }

    /// Process tensor input for a hexad
    async fn process_tensor(
        &self,
        id: &HexadId,
        input: &HexadTensorInput,
    ) -> Result<Tensor, HexadError> {
        let tensor = Tensor::new(id.as_str(), input.shape.clone(), input.data.clone()).map_err(
            |e| HexadError::ModalityError {
                modality: "tensor".to_string(),
                message: e.to_string(),
            },
        )?;

        self.tensor.put(&tensor).await.map_err(|e| HexadError::ModalityError {
            modality: "tensor".to_string(),
            message: e.to_string(),
        })?;

        debug!(id = %id, shape = ?input.shape, "Tensor modality populated");
        Ok(tensor)
    }

    /// Process semantic input for a hexad
    async fn process_semantic(
        &self,
        id: &HexadId,
        input: &HexadSemanticInput,
    ) -> Result<SemanticAnnotation, HexadError> {
        let mut properties = HashMap::new();
        for (key, value) in &input.properties {
            properties.insert(
                key.clone(),
                SemanticValue::TypedLiteral {
                    value: value.clone(),
                    datatype: "https://www.w3.org/2001/XMLSchema#string".to_string(),
                },
            );
        }

        let annotation = SemanticAnnotation {
            entity_id: id.as_str().to_string(),
            types: input.types.clone(),
            properties,
            provenance: Provenance::default(),
        };

        self.semantic.annotate(&annotation).await.map_err(|e| HexadError::ModalityError {
            modality: "semantic".to_string(),
            message: e.to_string(),
        })?;

        debug!(id = %id, types = ?input.types, "Semantic modality populated");
        Ok(annotation)
    }

    /// Create a snapshot for versioning
    fn create_snapshot(&self, id: &HexadId, input: &HexadInput, status: &ModalityStatus) -> HexadSnapshot {
        HexadSnapshot {
            id: id.clone(),
            input: input.clone(),
            modality_status: status.clone(),
            timestamp: Utc::now(),
        }
    }

    /// Load a complete Hexad from all stores
    async fn load_hexad(&self, id: &HexadId) -> Result<Option<Hexad>, HexadError> {
        let hexads = self.hexads.read().await;
        let status = match hexads.get(id.as_str()) {
            Some(s) => s.clone(),
            None => return Ok(None),
        };
        drop(hexads);

        // Load each modality
        let graph_node = if status.modality_status.graph {
            Some(GraphNode::new(id.to_iri(&self.config.base_iri)))
        } else {
            None
        };

        let embedding = if status.modality_status.vector {
            self.vector.get(id.as_str()).await.map_err(|e| HexadError::ModalityError {
                modality: "vector".to_string(),
                message: e.to_string(),
            })?
        } else {
            None
        };

        let document = if status.modality_status.document {
            self.document.get(id.as_str()).await.map_err(|e| HexadError::ModalityError {
                modality: "document".to_string(),
                message: e.to_string(),
            })?
        } else {
            None
        };

        let tensor = if status.modality_status.tensor {
            self.tensor.get(id.as_str()).await.map_err(|e| HexadError::ModalityError {
                modality: "tensor".to_string(),
                message: e.to_string(),
            })?
        } else {
            None
        };

        let semantic = if status.modality_status.semantic {
            self.semantic.get_annotations(id.as_str()).await.map_err(|e| HexadError::ModalityError {
                modality: "semantic".to_string(),
                message: e.to_string(),
            })?
        } else {
            None
        };

        let version_count = self
            .temporal
            .history(id.as_str(), 1000)
            .await
            .map(|h| h.len() as u64)
            .unwrap_or(0);

        Ok(Some(Hexad {
            id: id.clone(),
            status,
            graph_node,
            embedding,
            tensor,
            semantic,
            document,
            version_count,
        }))
    }
}

#[async_trait]
impl<G, V, D, T, S, R> HexadStore for InMemoryHexadStore<G, V, D, T, S, R>
where
    G: GraphStore + 'static,
    V: VectorStore + 'static,
    D: DocumentStore + 'static,
    T: TensorStore + 'static,
    S: SemanticStore + 'static,
    R: TemporalStore<Data = HexadSnapshot> + 'static,
{
    #[instrument(skip(self, input))]
    async fn create(&self, input: HexadInput) -> Result<Hexad, HexadError> {
        let id = HexadId::generate();
        let now = Utc::now();

        let mut modality_status = ModalityStatus::default();

        // Process each modality
        let mut graph_node = None;
        if let Some(ref graph_input) = input.graph {
            graph_node = Some(self.process_graph(&id, graph_input).await?);
            modality_status.graph = true;
        }

        let mut embedding = None;
        if let Some(ref vector_input) = input.vector {
            embedding = Some(self.process_vector(&id, vector_input).await?);
            modality_status.vector = true;
        }

        let mut document = None;
        if let Some(ref doc_input) = input.document {
            document = Some(self.process_document(&id, doc_input).await?);
            modality_status.document = true;
        }

        let mut tensor = None;
        if let Some(ref tensor_input) = input.tensor {
            tensor = Some(self.process_tensor(&id, tensor_input).await?);
            modality_status.tensor = true;
        }

        let mut semantic = None;
        if let Some(ref sem_input) = input.semantic {
            semantic = Some(self.process_semantic(&id, sem_input).await?);
            modality_status.semantic = true;
        }

        // Create version snapshot
        let snapshot = self.create_snapshot(&id, &input, &modality_status);
        let version = self
            .temporal
            .append(id.as_str(), snapshot, "system", Some("Initial creation"))
            .await
            .map_err(|e| HexadError::ModalityError {
                modality: "temporal".to_string(),
                message: e.to_string(),
            })?;
        modality_status.temporal = true;

        // Create status
        let status = HexadStatus {
            id: id.clone(),
            created_at: now,
            modified_at: now,
            version,
            modality_status: modality_status.clone(),
        };

        // Store in registry
        self.hexads.write().await.insert(id.as_str().to_string(), status.clone());

        info!(id = %id, modalities = ?modality_status, "Created hexad");

        Ok(Hexad {
            id,
            status,
            graph_node,
            embedding,
            tensor,
            semantic,
            document,
            version_count: 1,
        })
    }

    #[instrument(skip(self, input))]
    async fn update(&self, id: &HexadId, input: HexadInput) -> Result<Hexad, HexadError> {
        // Check if exists
        let existing = {
            let hexads = self.hexads.read().await;
            hexads.get(id.as_str()).cloned()
        };

        let existing = existing.ok_or_else(|| HexadError::NotFound(id.to_string()))?;
        let now = Utc::now();

        let mut modality_status = existing.modality_status.clone();

        // Update each modality
        let mut graph_node = None;
        if let Some(ref graph_input) = input.graph {
            graph_node = Some(self.process_graph(id, graph_input).await?);
            modality_status.graph = true;
        }

        let mut embedding = None;
        if let Some(ref vector_input) = input.vector {
            embedding = Some(self.process_vector(id, vector_input).await?);
            modality_status.vector = true;
        }

        let mut document = None;
        if let Some(ref doc_input) = input.document {
            document = Some(self.process_document(id, doc_input).await?);
            modality_status.document = true;
        }

        let mut tensor = None;
        if let Some(ref tensor_input) = input.tensor {
            tensor = Some(self.process_tensor(id, tensor_input).await?);
            modality_status.tensor = true;
        }

        let mut semantic = None;
        if let Some(ref sem_input) = input.semantic {
            semantic = Some(self.process_semantic(id, sem_input).await?);
            modality_status.semantic = true;
        }

        // Create new version snapshot
        let snapshot = self.create_snapshot(id, &input, &modality_status);
        let version = self
            .temporal
            .append(id.as_str(), snapshot, "system", Some("Update"))
            .await
            .map_err(|e| HexadError::ModalityError {
                modality: "temporal".to_string(),
                message: e.to_string(),
            })?;

        // Update status
        let status = HexadStatus {
            id: id.clone(),
            created_at: existing.created_at,
            modified_at: now,
            version,
            modality_status: modality_status.clone(),
        };

        // Update registry
        self.hexads.write().await.insert(id.as_str().to_string(), status.clone());

        info!(id = %id, version = version, "Updated hexad");

        Ok(Hexad {
            id: id.clone(),
            status,
            graph_node,
            embedding,
            tensor,
            semantic,
            document,
            version_count: version,
        })
    }

    async fn get(&self, id: &HexadId) -> Result<Option<Hexad>, HexadError> {
        self.load_hexad(id).await
    }

    #[instrument(skip(self))]
    async fn delete(&self, id: &HexadId) -> Result<(), HexadError> {
        // Remove from registry
        let status = {
            let mut hexads = self.hexads.write().await;
            hexads.remove(id.as_str())
        };

        if status.is_none() {
            return Err(HexadError::NotFound(id.to_string()));
        }

        // Delete from each modality store
        // Note: We don't delete from temporal to preserve history
        self.vector.delete(id.as_str()).await.ok();
        self.document.delete(id.as_str()).await.ok();
        self.tensor.delete(id.as_str()).await.ok();
        // Graph and semantic don't have simple delete-by-id

        info!(id = %id, "Deleted hexad");
        Ok(())
    }

    async fn status(&self, id: &HexadId) -> Result<Option<HexadStatus>, HexadError> {
        Ok(self.hexads.read().await.get(id.as_str()).cloned())
    }

    async fn search_similar(&self, embedding: &[f32], k: usize) -> Result<Vec<Hexad>, HexadError> {
        let results = self.vector.search(embedding, k).await.map_err(|e| HexadError::ModalityError {
            modality: "vector".to_string(),
            message: e.to_string(),
        })?;

        let mut hexads = Vec::new();
        for result in results {
            if let Some(hexad) = self.load_hexad(&HexadId::new(&result.id)).await? {
                hexads.push(hexad);
            }
        }

        Ok(hexads)
    }

    async fn search_text(&self, query: &str, limit: usize) -> Result<Vec<Hexad>, HexadError> {
        let results =
            self.document.search(query, limit).await.map_err(|e| HexadError::ModalityError {
                modality: "document".to_string(),
                message: e.to_string(),
            })?;

        let mut hexads = Vec::new();
        for result in results {
            if let Some(hexad) = self.load_hexad(&HexadId::new(&result.id)).await? {
                hexads.push(hexad);
            }
        }

        Ok(hexads)
    }

    async fn query_related(&self, id: &HexadId, predicate: &str) -> Result<Vec<Hexad>, HexadError> {
        let node = GraphNode::new(id.to_iri(&self.config.base_iri));
        let edges = self.graph.outgoing(&node).await.map_err(|e| HexadError::ModalityError {
            modality: "graph".to_string(),
            message: e.to_string(),
        })?;

        let predicate_iri = format!("{}/{}", self.config.base_iri, predicate);
        let mut hexads = Vec::new();

        for edge in edges {
            if edge.predicate.iri == predicate_iri {
                if let GraphObject::Node(target) = edge.object {
                    // Extract ID from IRI
                    let target_id = target
                        .iri
                        .strip_prefix(&format!("{}/", self.config.base_iri))
                        .unwrap_or(&target.iri);

                    if let Some(hexad) = self.load_hexad(&HexadId::new(target_id)).await? {
                        hexads.push(hexad);
                    }
                }
            }
        }

        Ok(hexads)
    }

    async fn list(&self, limit: usize, offset: usize) -> Result<Vec<Hexad>, HexadError> {
        let hexads = self.hexads.read().await;
        let ids: Vec<String> = hexads
            .keys()
            .skip(offset)
            .take(limit)
            .cloned()
            .collect();
        drop(hexads);

        let mut result = Vec::with_capacity(ids.len());
        for id_str in ids {
            if let Some(hexad) = self.load_hexad(&HexadId::new(&id_str)).await? {
                result.push(hexad);
            }
        }
        Ok(result)
    }

    async fn at_time(&self, id: &HexadId, time: DateTime<Utc>) -> Result<Option<Hexad>, HexadError> {
        let version = self
            .temporal
            .at_time(id.as_str(), time)
            .await
            .map_err(|e| HexadError::ModalityError {
                modality: "temporal".to_string(),
                message: e.to_string(),
            })?;

        match version {
            Some(v) => {
                // Reconstruct hexad from snapshot
                // For now, we just return current state with version info
                // A full implementation would restore from snapshot
                let mut hexad = self.load_hexad(id).await?;
                if let Some(ref mut h) = hexad {
                    h.status.version = v.version;
                    h.status.modified_at = v.timestamp;
                }
                Ok(hexad)
            }
            None => Ok(None),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::HexadBuilder;
    use verisim_document::TantivyDocumentStore;
    use verisim_graph::OxiGraphStore;
    use verisim_semantic::InMemorySemanticStore;
    use verisim_temporal::InMemoryVersionStore;
    use verisim_tensor::InMemoryTensorStore;
    use verisim_vector::{DistanceMetric, BruteForceVectorStore};

    fn create_test_store() -> InMemoryHexadStore<
        OxiGraphStore,
        BruteForceVectorStore,
        TantivyDocumentStore,
        InMemoryTensorStore,
        InMemorySemanticStore,
        InMemoryVersionStore<HexadSnapshot>,
    > {
        let config = HexadConfig {
            vector_dimension: 3,
            ..Default::default()
        };

        InMemoryHexadStore::new(
            config,
            Arc::new(OxiGraphStore::in_memory().unwrap()),
            Arc::new(BruteForceVectorStore::new(3, DistanceMetric::Cosine)),
            Arc::new(TantivyDocumentStore::in_memory().unwrap()),
            Arc::new(InMemoryTensorStore::new()),
            Arc::new(InMemorySemanticStore::new()),
            Arc::new(InMemoryVersionStore::new()),
        )
    }

    #[tokio::test]
    async fn test_create_and_get_hexad() {
        let store = create_test_store();

        let input = HexadBuilder::new()
            .with_document("Test Document", "This is a test body")
            .with_embedding(vec![0.1, 0.2, 0.3])
            .build();

        let hexad = store.create(input).await.unwrap();
        assert!(hexad.status.modality_status.document);
        assert!(hexad.status.modality_status.vector);
        assert!(hexad.status.modality_status.temporal);

        let retrieved = store.get(&hexad.id).await.unwrap();
        assert!(retrieved.is_some());
        let retrieved = retrieved.unwrap();
        assert_eq!(retrieved.id, hexad.id);
    }

    #[tokio::test]
    async fn test_vector_search() {
        let store = create_test_store();

        let input1 = HexadBuilder::new()
            .with_document("First", "First document")
            .with_embedding(vec![1.0, 0.0, 0.0])
            .build();

        let input2 = HexadBuilder::new()
            .with_document("Second", "Second document")
            .with_embedding(vec![0.9, 0.1, 0.0])
            .build();

        let input3 = HexadBuilder::new()
            .with_document("Third", "Third document")
            .with_embedding(vec![0.0, 1.0, 0.0])
            .build();

        store.create(input1).await.unwrap();
        store.create(input2).await.unwrap();
        store.create(input3).await.unwrap();

        let results = store.search_similar(&[1.0, 0.0, 0.0], 2).await.unwrap();
        assert_eq!(results.len(), 2);
    }

    #[tokio::test]
    async fn test_document_search() {
        let store = create_test_store();

        let input1 = HexadBuilder::new()
            .with_document("Rust Programming", "Rust is a systems programming language")
            .with_embedding(vec![0.1, 0.2, 0.3])
            .build();

        let input2 = HexadBuilder::new()
            .with_document("Python Tutorial", "Python is great for beginners")
            .with_embedding(vec![0.4, 0.5, 0.6])
            .build();

        store.create(input1).await.unwrap();
        store.create(input2).await.unwrap();

        let results = store.search_text("Rust", 10).await.unwrap();
        assert_eq!(results.len(), 1);
        assert!(results[0].document.as_ref().unwrap().title.contains("Rust"));
    }

    #[tokio::test]
    async fn test_update_hexad() {
        let store = create_test_store();

        let input = HexadBuilder::new()
            .with_document("Original", "Original content")
            .with_embedding(vec![0.1, 0.2, 0.3])
            .build();

        let hexad = store.create(input).await.unwrap();
        assert_eq!(hexad.status.version, 1);

        let update_input = HexadBuilder::new()
            .with_document("Updated", "Updated content")
            .build();

        let updated = store.update(&hexad.id, update_input).await.unwrap();
        assert_eq!(updated.status.version, 2);
        assert!(updated.document.as_ref().unwrap().title.contains("Updated"));
    }
}
