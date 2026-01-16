// SPDX-License-Identifier: AGPL-3.0-or-later
//! VeriSim Vector Modality
//!
//! HNSW-based similarity search for embeddings.
//! Implements Marr's Computational Level: "What is similar to what?"

use async_trait::async_trait;
use hnsw_rs::prelude::*;
use ndarray::{Array1, ArrayView1};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::{Arc, RwLock};
use thiserror::Error;

/// Vector modality errors
#[derive(Error, Debug)]
pub enum VectorError {
    #[error("Dimension mismatch: expected {expected}, got {actual}")]
    DimensionMismatch { expected: usize, actual: usize },

    #[error("Vector not found: {0}")]
    NotFound(String),

    #[error("Index error: {0}")]
    IndexError(String),

    #[error("Serialization error: {0}")]
    SerializationError(String),
}

/// A vector embedding with metadata
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Embedding {
    /// Unique identifier (matches Hexad entity ID)
    pub id: String,
    /// The embedding vector
    pub vector: Vec<f32>,
    /// Optional metadata
    pub metadata: HashMap<String, String>,
}

impl Embedding {
    /// Create a new embedding
    pub fn new(id: impl Into<String>, vector: Vec<f32>) -> Self {
        Self {
            id: id.into(),
            vector,
            metadata: HashMap::new(),
        }
    }

    /// Add metadata
    pub fn with_metadata(mut self, key: impl Into<String>, value: impl Into<String>) -> Self {
        self.metadata.insert(key.into(), value.into());
        self
    }

    /// Get dimensionality
    pub fn dim(&self) -> usize {
        self.vector.len()
    }

    /// Convert to ndarray
    pub fn as_array(&self) -> Array1<f32> {
        Array1::from_vec(self.vector.clone())
    }
}

/// Search result with score
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SearchResult {
    /// Entity ID
    pub id: String,
    /// Similarity score (higher is more similar for cosine)
    pub score: f32,
}

/// Distance metric for similarity
#[derive(Debug, Clone, Copy, Serialize, Deserialize, Default)]
pub enum DistanceMetric {
    #[default]
    Cosine,
    Euclidean,
    DotProduct,
}

/// Vector store trait for cross-modal consistency
#[async_trait]
pub trait VectorStore: Send + Sync {
    /// Insert or update an embedding
    async fn upsert(&self, embedding: &Embedding) -> Result<(), VectorError>;

    /// Search for similar vectors
    async fn search(&self, query: &[f32], k: usize) -> Result<Vec<SearchResult>, VectorError>;

    /// Get embedding by ID
    async fn get(&self, id: &str) -> Result<Option<Embedding>, VectorError>;

    /// Delete embedding by ID
    async fn delete(&self, id: &str) -> Result<(), VectorError>;

    /// Get the dimensionality of the index
    fn dimension(&self) -> usize;
}

/// HNSW-based vector store
pub struct HnswVectorStore {
    dimension: usize,
    metric: DistanceMetric,
    hnsw: Arc<RwLock<Hnsw<f32, DistCosine>>>,
    id_to_index: Arc<RwLock<HashMap<String, usize>>>,
    index_to_id: Arc<RwLock<HashMap<usize, String>>>,
    embeddings: Arc<RwLock<HashMap<String, Embedding>>>,
    next_index: Arc<RwLock<usize>>,
}

impl HnswVectorStore {
    /// Create a new HNSW vector store
    pub fn new(dimension: usize, metric: DistanceMetric) -> Self {
        let max_elements = 100_000; // Initial capacity
        let max_nb_connection = 16; // M parameter
        let ef_construction = 200;

        let hnsw = Hnsw::new(max_nb_connection, max_elements, 16, ef_construction, DistCosine);

        Self {
            dimension,
            metric,
            hnsw: Arc::new(RwLock::new(hnsw)),
            id_to_index: Arc::new(RwLock::new(HashMap::new())),
            index_to_id: Arc::new(RwLock::new(HashMap::new())),
            embeddings: Arc::new(RwLock::new(HashMap::new())),
            next_index: Arc::new(RwLock::new(0)),
        }
    }

    /// Normalize vector for cosine similarity
    fn normalize(v: &[f32]) -> Vec<f32> {
        let norm: f32 = v.iter().map(|x| x * x).sum::<f32>().sqrt();
        if norm > 0.0 {
            v.iter().map(|x| x / norm).collect()
        } else {
            v.to_vec()
        }
    }
}

#[async_trait]
impl VectorStore for HnswVectorStore {
    async fn upsert(&self, embedding: &Embedding) -> Result<(), VectorError> {
        if embedding.dim() != self.dimension {
            return Err(VectorError::DimensionMismatch {
                expected: self.dimension,
                actual: embedding.dim(),
            });
        }

        let normalized = Self::normalize(&embedding.vector);

        // Get or assign index
        let index = {
            let mut id_to_index = self.id_to_index.write().unwrap();
            if let Some(&idx) = id_to_index.get(&embedding.id) {
                idx
            } else {
                let mut next = self.next_index.write().unwrap();
                let idx = *next;
                *next += 1;
                id_to_index.insert(embedding.id.clone(), idx);
                self.index_to_id.write().unwrap().insert(idx, embedding.id.clone());
                idx
            }
        };

        // Insert into HNSW
        {
            let mut hnsw = self.hnsw.write().unwrap();
            hnsw.insert((&normalized, index));
        }

        // Store embedding
        self.embeddings.write().unwrap().insert(embedding.id.clone(), embedding.clone());

        Ok(())
    }

    async fn search(&self, query: &[f32], k: usize) -> Result<Vec<SearchResult>, VectorError> {
        if query.len() != self.dimension {
            return Err(VectorError::DimensionMismatch {
                expected: self.dimension,
                actual: query.len(),
            });
        }

        let normalized = Self::normalize(query);

        let hnsw = self.hnsw.read().unwrap();
        let ef_search = k.max(50); // ef >= k
        let neighbors = hnsw.search(&normalized, k, ef_search);

        let index_to_id = self.index_to_id.read().unwrap();
        let results = neighbors
            .into_iter()
            .filter_map(|n| {
                index_to_id.get(&n.d_id).map(|id| SearchResult {
                    id: id.clone(),
                    score: 1.0 - n.distance, // Convert distance to similarity
                })
            })
            .collect();

        Ok(results)
    }

    async fn get(&self, id: &str) -> Result<Option<Embedding>, VectorError> {
        Ok(self.embeddings.read().unwrap().get(id).cloned())
    }

    async fn delete(&self, id: &str) -> Result<(), VectorError> {
        self.embeddings.write().unwrap().remove(id);
        // Note: HNSW doesn't support true deletion, marked for rebuild
        Ok(())
    }

    fn dimension(&self) -> usize {
        self.dimension
    }
}

/// Compute cosine similarity between two vectors
pub fn cosine_similarity(a: ArrayView1<f32>, b: ArrayView1<f32>) -> f32 {
    let dot: f32 = a.iter().zip(b.iter()).map(|(x, y)| x * y).sum();
    let norm_a: f32 = a.iter().map(|x| x * x).sum::<f32>().sqrt();
    let norm_b: f32 = b.iter().map(|x| x * x).sum::<f32>().sqrt();
    if norm_a > 0.0 && norm_b > 0.0 {
        dot / (norm_a * norm_b)
    } else {
        0.0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_upsert_and_search() {
        let store = HnswVectorStore::new(3, DistanceMetric::Cosine);

        let e1 = Embedding::new("e1", vec![1.0, 0.0, 0.0]);
        let e2 = Embedding::new("e2", vec![0.9, 0.1, 0.0]);
        let e3 = Embedding::new("e3", vec![0.0, 1.0, 0.0]);

        store.upsert(&e1).await.unwrap();
        store.upsert(&e2).await.unwrap();
        store.upsert(&e3).await.unwrap();

        let results = store.search(&[1.0, 0.0, 0.0], 2).await.unwrap();
        assert_eq!(results.len(), 2);
        assert_eq!(results[0].id, "e1");
    }
}
