// SPDX-License-Identifier: AGPL-3.0-or-later
//! Integration tests for VeriSimDB
//!
//! Tests cross-modal consistency, persistence, and end-to-end workflows.

use std::sync::Arc;
use verisim_hexad::{
    HexadBuilder, HexadConfig, HexadId, HexadStore, InMemoryHexadStore,
};
use verisim_document::TantivyDocumentStore;
use verisim_graph::OxiGraphStore;
use verisim_semantic::InMemorySemanticStore;
use verisim_temporal::InMemoryVersionStore;
use verisim_tensor::InMemoryTensorStore;
use verisim_vector::{DistanceMetric, HnswVectorStore, HnswConfig};

type TestHexadStore = InMemoryHexadStore<
    OxiGraphStore,
    HnswVectorStore,
    TantivyDocumentStore,
    InMemoryTensorStore,
    InMemorySemanticStore,
    InMemoryVersionStore<verisim_hexad::HexadSnapshot>,
>;

fn create_test_store(vector_dim: usize) -> TestHexadStore {
    let config = HexadConfig {
        vector_dimension: vector_dim,
        ..Default::default()
    };

    InMemoryHexadStore::new(
        config,
        Arc::new(OxiGraphStore::in_memory().unwrap()),
        Arc::new(HnswVectorStore::new(vector_dim, DistanceMetric::Cosine)),
        Arc::new(TantivyDocumentStore::in_memory().unwrap()),
        Arc::new(InMemoryTensorStore::new()),
        Arc::new(InMemorySemanticStore::new()),
        Arc::new(InMemoryVersionStore::new()),
    )
}

/// Test that all six modalities are properly synchronized
#[tokio::test]
async fn test_cross_modal_consistency() {
    let store = create_test_store(128);

    // Create a hexad with all modalities populated
    let input = HexadBuilder::new()
        .with_document("Cross-Modal Test", "Testing all modalities together")
        .with_embedding(vec![0.1; 128])
        .with_tensor(vec![2, 2], vec![1.0, 2.0, 3.0, 4.0])
        .with_semantic(vec!["http://example.org/TestType".to_string()])
        .with_relationship("relatedTo", "other-entity")
        .build();

    let hexad = store.create(input).await.unwrap();

    // Verify all modalities are populated
    let status = &hexad.status.modality_status;
    assert!(status.graph, "Graph modality should be populated");
    assert!(status.vector, "Vector modality should be populated");
    assert!(status.tensor, "Tensor modality should be populated");
    assert!(status.semantic, "Semantic modality should be populated");
    assert!(status.document, "Document modality should be populated");
    assert!(status.temporal, "Temporal modality should be populated");

    // Verify the hexad can be retrieved
    let retrieved = store.get(&hexad.id).await.unwrap();
    assert!(retrieved.is_some(), "Hexad should be retrievable");

    let retrieved = retrieved.unwrap();
    assert_eq!(retrieved.id, hexad.id);
    assert!(retrieved.embedding.is_some());
    assert!(retrieved.tensor.is_some());
    assert!(retrieved.semantic.is_some());
    assert!(retrieved.document.is_some());
}

/// Test vector similarity search with HNSW
#[tokio::test]
async fn test_vector_similarity_search() {
    let store = create_test_store(3);

    // Create entities with different embeddings
    let inputs = vec![
        (vec![1.0, 0.0, 0.0], "X-axis aligned"),
        (vec![0.9, 0.1, 0.0], "Near X-axis"),
        (vec![0.0, 1.0, 0.0], "Y-axis aligned"),
        (vec![0.0, 0.0, 1.0], "Z-axis aligned"),
    ];

    for (embedding, title) in &inputs {
        let input = HexadBuilder::new()
            .with_document(title, &format!("Entity at {:?}", embedding))
            .with_embedding(embedding.clone())
            .build();
        store.create(input).await.unwrap();
    }

    // Search for entities similar to X-axis
    let results = store.search_similar(&[1.0, 0.0, 0.0], 2).await.unwrap();
    assert_eq!(results.len(), 2);

    // The two closest should be X-axis and near-X-axis
    let titles: Vec<_> = results
        .iter()
        .filter_map(|h| h.document.as_ref().map(|d| d.title.as_str()))
        .collect();

    assert!(
        titles.contains(&"X-axis aligned") || titles.contains(&"Near X-axis"),
        "Search results should include X-axis or near-X-axis entities"
    );
}

/// Test full-text search across documents
#[tokio::test]
async fn test_full_text_search() {
    let store = create_test_store(3);

    // Create entities with different content
    let docs = vec![
        ("Rust Programming", "Rust is a systems programming language focused on safety"),
        ("Python Guide", "Python is a high-level programming language"),
        ("Database Design", "Relational databases use SQL for querying"),
    ];

    for (title, body) in &docs {
        let input = HexadBuilder::new()
            .with_document(title, body)
            .with_embedding(vec![0.1, 0.2, 0.3])
            .build();
        store.create(input).await.unwrap();
    }

    // Search for "Rust"
    let results = store.search_text("Rust", 10).await.unwrap();
    assert_eq!(results.len(), 1);
    assert!(results[0].document.as_ref().unwrap().title.contains("Rust"));

    // Search for "programming" - should match multiple
    let results = store.search_text("programming", 10).await.unwrap();
    assert!(results.len() >= 2, "Should match at least 2 programming docs");
}

/// Test temporal versioning
#[tokio::test]
async fn test_versioning() {
    let store = create_test_store(3);

    // Create initial entity
    let input = HexadBuilder::new()
        .with_document("Version 1", "Initial content")
        .with_embedding(vec![0.1, 0.2, 0.3])
        .build();

    let hexad = store.create(input).await.unwrap();
    assert_eq!(hexad.status.version, 1);

    // Update the entity
    let update1 = HexadBuilder::new()
        .with_document("Version 2", "Updated content")
        .build();

    let updated = store.update(&hexad.id, update1).await.unwrap();
    assert_eq!(updated.status.version, 2);

    // Update again
    let update2 = HexadBuilder::new()
        .with_document("Version 3", "Final content")
        .build();

    let updated = store.update(&hexad.id, update2).await.unwrap();
    assert_eq!(updated.status.version, 3);
    assert_eq!(updated.version_count, 3);
}

/// Test CRUD operations
#[tokio::test]
async fn test_crud_operations() {
    let store = create_test_store(3);

    // Create
    let input = HexadBuilder::new()
        .with_document("Test Entity", "Test body")
        .with_embedding(vec![0.1, 0.2, 0.3])
        .build();

    let hexad = store.create(input).await.unwrap();
    let id = hexad.id.clone();

    // Read
    let retrieved = store.get(&id).await.unwrap();
    assert!(retrieved.is_some());

    // Update
    let update_input = HexadBuilder::new()
        .with_document("Updated Entity", "Updated body")
        .build();

    let updated = store.update(&id, update_input).await.unwrap();
    assert!(updated.document.as_ref().unwrap().title.contains("Updated"));

    // Delete
    store.delete(&id).await.unwrap();

    // Verify deletion
    let deleted = store.get(&id).await.unwrap();
    assert!(deleted.is_none());
}

/// Test vector store persistence
#[tokio::test]
async fn test_vector_persistence() {
    use std::fs;
    let temp_path = "/tmp/verisim_integration_vector_test.bin";

    // Create and populate vector store
    let config = HnswConfig {
        rebuild_threshold: 5,
        use_hnsw: true,
        ..Default::default()
    };
    let store = HnswVectorStore::with_config(64, DistanceMetric::Cosine, config);

    // Insert vectors
    for i in 0..20 {
        let mut vec = vec![0.0f32; 64];
        vec[i % 64] = 1.0;
        let embedding = verisim_vector::Embedding::new(format!("vec_{}", i), vec);
        store.upsert(&embedding).await.unwrap();
    }

    // Rebuild HNSW index
    store.rebuild_index().unwrap();

    // Save to file
    store.save_to_file(temp_path).unwrap();

    // Load from file
    let loaded = HnswVectorStore::load_from_file(temp_path).unwrap();

    // Verify data
    assert_eq!(loaded.stats().total_vectors, 20);

    // Search should work
    let mut query = vec![0.0f32; 64];
    query[0] = 1.0;
    let results = loaded.search(&query, 3).await.unwrap();
    assert_eq!(results.len(), 3);
    assert_eq!(results[0].id, "vec_0");

    // Cleanup
    fs::remove_file(temp_path).ok();
}

/// Test tensor store persistence
#[tokio::test]
async fn test_tensor_persistence() {
    use std::fs;
    use verisim_tensor::{Tensor, TensorStore as _};

    let temp_path = "/tmp/verisim_integration_tensor_test.bin";

    // Create and populate tensor store
    let store = InMemoryTensorStore::new();

    let t1 = Tensor::new("tensor_1", vec![2, 3], vec![1.0, 2.0, 3.0, 4.0, 5.0, 6.0]).unwrap();
    let t2 = Tensor::new("tensor_2", vec![3, 3], vec![1.0; 9]).unwrap();

    store.put(&t1).await.unwrap();
    store.put(&t2).await.unwrap();

    // Save to file
    store.save_to_file(temp_path).unwrap();

    // Load from file
    let loaded = InMemoryTensorStore::load_from_file(temp_path).unwrap();

    // Verify data
    let retrieved = loaded.get("tensor_1").await.unwrap().unwrap();
    assert_eq!(retrieved.shape, vec![2, 3]);
    assert_eq!(retrieved.data, vec![1.0, 2.0, 3.0, 4.0, 5.0, 6.0]);

    let list = loaded.list().await.unwrap();
    assert_eq!(list.len(), 2);

    // Cleanup
    fs::remove_file(temp_path).ok();
}

/// Test semantic store persistence
#[tokio::test]
async fn test_semantic_persistence() {
    use std::fs;
    use verisim_semantic::{SemanticStore as _, SemanticType, Constraint, ConstraintKind};

    let temp_path = "/tmp/verisim_integration_semantic_test.bin";

    // Create and populate semantic store
    let store = InMemorySemanticStore::new();

    let person_type = SemanticType::new("http://example.org/Person", "Person")
        .with_supertype("http://example.org/Entity")
        .with_constraint(Constraint {
            name: "name_required".to_string(),
            kind: ConstraintKind::Required("name".to_string()),
            message: "Person must have a name".to_string(),
        });

    let org_type = SemanticType::new("http://example.org/Organization", "Organization");

    store.register_type(&person_type).await.unwrap();
    store.register_type(&org_type).await.unwrap();

    // Save to file
    store.save_to_file(temp_path).unwrap();

    // Load from file
    let loaded = InMemorySemanticStore::load_from_file(temp_path).unwrap();

    // Verify types
    let retrieved = loaded.get_type("http://example.org/Person").await.unwrap().unwrap();
    assert_eq!(retrieved.label, "Person");
    assert_eq!(retrieved.constraints.len(), 1);

    let org = loaded.get_type("http://example.org/Organization").await.unwrap();
    assert!(org.is_some());

    // Cleanup
    fs::remove_file(temp_path).ok();
}

/// Test temporal store persistence
#[tokio::test]
async fn test_temporal_persistence() {
    use std::fs;
    use verisim_temporal::TemporalStore as _;

    let temp_path = "/tmp/verisim_integration_temporal_test.bin";

    // Create and populate temporal store
    let store: InMemoryVersionStore<String> = InMemoryVersionStore::new();

    store.append("entity1", "v1 data".to_string(), "alice", Some("first")).await.unwrap();
    store.append("entity1", "v2 data".to_string(), "bob", Some("second")).await.unwrap();
    store.append("entity2", "other data".to_string(), "charlie", None).await.unwrap();

    // Save to file
    store.save_to_file(temp_path).unwrap();

    // Load from file
    let loaded: InMemoryVersionStore<String> = InMemoryVersionStore::load_from_file(temp_path).unwrap();

    // Verify versions
    let latest = loaded.latest("entity1").await.unwrap().unwrap();
    assert_eq!(latest.version, 2);
    assert_eq!(latest.data, "v2 data");

    let v1 = loaded.at_version("entity1", 1).await.unwrap().unwrap();
    assert_eq!(v1.data, "v1 data");

    let history = loaded.history("entity1", 10).await.unwrap();
    assert_eq!(history.len(), 2);

    // Cleanup
    fs::remove_file(temp_path).ok();
}

/// Test that modality operations are isolated
#[tokio::test]
async fn test_modality_isolation() {
    let store = create_test_store(3);

    // Create entity with only document
    let input1 = HexadBuilder::new()
        .with_document("Doc Only", "Only document modality")
        .build();

    let h1 = store.create(input1).await.unwrap();
    assert!(h1.status.modality_status.document);
    assert!(!h1.status.modality_status.vector);
    assert!(!h1.status.modality_status.tensor);

    // Create entity with only vector
    let input2 = HexadBuilder::new()
        .with_embedding(vec![0.1, 0.2, 0.3])
        .build();

    let h2 = store.create(input2).await.unwrap();
    assert!(!h2.status.modality_status.document);
    assert!(h2.status.modality_status.vector);
    assert!(!h2.status.modality_status.tensor);

    // Verify searches don't cross-contaminate
    let doc_results = store.search_text("Only document", 10).await.unwrap();
    assert_eq!(doc_results.len(), 1);

    // Vector search should only find vector-enabled entities
    let vec_results = store.search_similar(&[0.1, 0.2, 0.3], 10).await.unwrap();
    // h2 has vector, h1 does not
    let vec_ids: Vec<_> = vec_results.iter().map(|h| h.id.as_str()).collect();
    assert!(vec_ids.contains(&h2.id.as_str()));
}

/// Test high-dimension HNSW performance
#[tokio::test]
async fn test_high_dimension_hnsw() {
    let store = create_test_store(768); // BERT-like dimension

    // Create 50 entities with high-dimensional embeddings
    for i in 0..50 {
        let mut embedding = vec![0.0f32; 768];
        embedding[i % 768] = 1.0;
        embedding[(i * 7) % 768] = 0.5;

        let input = HexadBuilder::new()
            .with_document(&format!("Entity {}", i), &format!("High-dim entity number {}", i))
            .with_embedding(embedding)
            .build();

        store.create(input).await.unwrap();
    }

    // Search should complete quickly even with high dimensions
    let mut query = vec![0.0f32; 768];
    query[0] = 1.0;

    let results = store.search_similar(&query, 5).await.unwrap();
    assert_eq!(results.len(), 5);
}
