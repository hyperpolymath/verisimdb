// SPDX-License-Identifier: PMPL-1.0-or-later
//! Performance benchmarks for VeriSimDB modality stores

use criterion::{black_box, criterion_group, criterion_main, BenchmarkId, Criterion, Throughput};
use std::collections::HashMap;
use tokio::runtime::Runtime;

use verisim_document::{Document, TantivyDocumentStore};
use verisim_drift::{DriftDetector, DriftMetrics, DriftThresholds};
use verisim_graph::{GraphEdge, GraphNode, OxiGraphStore};
use verisim_hexad::{
    HexadConfig, HexadDocumentInput, HexadId, HexadInput, HexadStore, InMemoryHexadStore,
};
use verisim_normalizer::{create_default_normalizer, Normalizer};
use verisim_semantic::InMemorySemanticStore;
use verisim_temporal::{InMemoryVersionStore, Version};
use verisim_tensor::{InMemoryTensorStore, Tensor};
use verisim_vector::{DistanceMetric, Embedding, HnswVectorStore};

// ============================================================================
// Document Store Benchmarks
// ============================================================================

fn bench_document_create(c: &mut Criterion) {
    let rt = Runtime::new().unwrap();
    let temp_dir = std::env::temp_dir().join(format!("bench-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&temp_dir).unwrap();

    let mut group = c.benchmark_group("document");

    group.bench_function("create_document", |b| {
        let store = TantivyDocumentStore::new(&temp_dir).unwrap();
        b.to_async(&rt).iter(|| async {
            let doc = Document::new("test-id", "Benchmark Title", "Benchmark body content for testing indexing performance.");
            black_box(store.index(&doc).await.unwrap())
        });
    });

    group.finish();
    std::fs::remove_dir_all(&temp_dir).ok();
}

fn bench_document_search(c: &mut Criterion) {
    let rt = Runtime::new().unwrap();
    let temp_dir = std::env::temp_dir().join(format!("bench-search-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&temp_dir).unwrap();

    let mut store = TantivyDocumentStore::new(&temp_dir).unwrap();

    // Index 1000 documents
    rt.block_on(async {
        for i in 0..1000 {
            let doc = Document::new(
                format!("doc-{}", i),
                format!("Document {}", i),
                format!("This is document number {} with searchable content about machine learning and databases.", i),
            );
            store.index(&doc).await.unwrap();
        }
    });

    let mut group = c.benchmark_group("document");
    group.throughput(Throughput::Elements(1000));

    group.bench_function("search_text", |b| {
        b.to_async(&rt).iter(|| async {
            black_box(store.search("machine learning", 10).await.unwrap())
        });
    });

    group.finish();
    std::fs::remove_dir_all(&temp_dir).ok();
}

// ============================================================================
// Vector Store Benchmarks
// ============================================================================

fn bench_vector_insert(c: &mut Criterion) {
    let rt = Runtime::new().unwrap();
    let mut group = c.benchmark_group("vector");

    for dim in [128, 384, 768].iter() {
        group.bench_with_input(BenchmarkId::new("insert", dim), dim, |b, &dim| {
            let mut store = HnswVectorStore::new(dim, DistanceMetric::Cosine).unwrap();
            let embedding = vec![0.5; dim];
            let id = HexadId::generate();

            b.to_async(&rt).iter(|| async {
                black_box(store.insert(&id, &embedding).await.unwrap())
            });
        });
    }

    group.finish();
}

fn bench_vector_search(c: &mut Criterion) {
    let rt = Runtime::new().unwrap();
    let mut group = c.benchmark_group("vector");

    for dim in [128, 384, 768].iter() {
        group.bench_with_input(BenchmarkId::new("search", dim), dim, |b, &dim| {
            let mut store = HnswVectorStore::new(dim, DistanceMetric::Cosine).unwrap();

            // Insert 10000 vectors
            rt.block_on(async {
                for i in 0..10000 {
                    let mut embedding = vec![0.0; dim];
                    embedding[0] = (i as f32) / 10000.0;
                    let id = HexadId::new(format!("vec-{}", i));
                    store.insert(&id, &embedding).await.unwrap();
                }
            });

            let query = vec![0.5; dim];

            b.to_async(&rt).iter(|| async {
                black_box(store.search_similar(&query, 10, Some(0.0)).await.unwrap())
            });
        });
    }

    group.throughput(Throughput::Elements(10000));
    group.finish();
}

// ============================================================================
// Graph Store Benchmarks
// ============================================================================

fn bench_graph_operations(c: &mut Criterion) {
    let rt = Runtime::new().unwrap();
    let mut group = c.benchmark_group("graph");

    group.bench_function("add_node", |b| {
        let mut store = OxiGraphStore::new_in_memory().unwrap();
        b.to_async(&rt).iter(|| async {
            let node = GraphNode {
                id: HexadId::generate().to_string(),
                properties: HashMap::new(),
            };
            black_box(store.add_node(&node).await.unwrap())
        });
    });

    group.bench_function("add_edge", |b| {
        let mut store = OxiGraphStore::new_in_memory().unwrap();
        let from = HexadId::new("from-node");
        let to = HexadId::new("to-node");

        rt.block_on(async {
            store.add_node(&GraphNode { id: from.to_string(), properties: HashMap::new() }).await.unwrap();
            store.add_node(&GraphNode { id: to.to_string(), properties: HashMap::new() }).await.unwrap();
        });

        b.to_async(&rt).iter(|| async {
            let edge = GraphEdge {
                from: from.clone(),
                to: to.clone(),
                predicate: "relates_to".to_string(),
                properties: HashMap::new(),
            };
            black_box(store.add_edge(&edge).await.unwrap())
        });
    });

    group.finish();
}

// ============================================================================
// Hexad Store Benchmarks
// ============================================================================

fn bench_hexad_operations(c: &mut Criterion) {
    let rt = Runtime::new().unwrap();
    let mut group = c.benchmark_group("hexad");

    let temp_dir = std::env::temp_dir().join(format!("bench-hexad-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&temp_dir).unwrap();

    let graph_store = OxiGraphStore::new_in_memory().unwrap();
    let vector_store = HnswVectorStore::new(384, DistanceMetric::Cosine).unwrap();
    let document_store = TantivyDocumentStore::new(&temp_dir).unwrap();
    let tensor_store = InMemoryTensorStore::new();
    let semantic_store = InMemorySemanticStore::new();
    let temporal_store = InMemoryVersionStore::new();

    let config = HexadConfig {
        enable_drift_detection: true,
        drift_thresholds: DriftThresholds::default(),
        enable_auto_normalization: false,
        ..Default::default()
    };

    let mut store = InMemoryHexadStore::new(
        graph_store,
        vector_store,
        document_store,
        tensor_store,
        semantic_store,
        temporal_store,
        config,
    );

    group.bench_function("create_hexad", |b| {
        b.to_async(&rt).iter(|| async {
            let input = HexadInput {
                document: Some(HexadDocumentInput {
                    title: "Benchmark Hexad".to_string(),
                    body: "Testing hexad creation performance.".to_string(),
                    fields: HashMap::new(),
                }),
                vector: Some(vec![0.5; 384].into()),
                ..Default::default()
            };
            black_box(store.create(input).await.unwrap())
        });
    });

    // Create hexads for retrieval benchmark
    let mut hexad_ids = vec![];
    rt.block_on(async {
        for i in 0..100 {
            let input = HexadInput {
                document: Some(HexadDocumentInput {
                    title: format!("Hexad {}", i),
                    body: format!("Content {}", i),
                    fields: HashMap::new(),
                }),
                vector: Some(vec![i as f32 / 100.0; 384].into()),
                ..Default::default()
            };
            hexad_ids.push(store.create(input).await.unwrap());
        }
    });

    group.bench_function("get_hexad", |b| {
        let id = hexad_ids[0].clone();
        b.to_async(&rt).iter(|| async {
            black_box(store.get(&id).await.unwrap())
        });
    });

    group.finish();
    std::fs::remove_dir_all(&temp_dir).ok();
}

// ============================================================================
// Drift Detection Benchmarks
// ============================================================================

fn bench_drift_detection(c: &mut Criterion) {
    let mut group = c.benchmark_group("drift");

    let detector = DriftDetector::new(DriftThresholds::default());

    group.bench_function("calculate_drift", |b| {
        let doc_vec = vec![0.5; 384];
        let actual_vec = vec![0.6; 384];

        b.iter(|| {
            black_box(detector.calculate_semantic_vector_drift(&doc_vec, &actual_vec))
        });
    });

    group.finish();
}

// ============================================================================
// Cross-Modal Query Benchmarks
// ============================================================================

fn bench_cross_modal_query(c: &mut Criterion) {
    let rt = Runtime::new().unwrap();
    let mut group = c.benchmark_group("cross_modal");

    let temp_dir = std::env::temp_dir().join(format!("bench-cross-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&temp_dir).unwrap();

    let graph_store = OxiGraphStore::new_in_memory().unwrap();
    let vector_store = HnswVectorStore::new(384, DistanceMetric::Cosine).unwrap();
    let document_store = TantivyDocumentStore::new(&temp_dir).unwrap();
    let tensor_store = InMemoryTensorStore::new();
    let semantic_store = InMemorySemanticStore::new();
    let temporal_store = InMemoryVersionStore::new();

    let config = HexadConfig::default();

    let mut store = InMemoryHexadStore::new(
        graph_store,
        vector_store,
        document_store,
        tensor_store,
        semantic_store,
        temporal_store,
        config,
    );

    // Create 1000 hexads with multiple modalities
    rt.block_on(async {
        for i in 0..1000 {
            let mut embedding = vec![0.0; 384];
            embedding[0] = (i as f32) / 1000.0;

            let input = HexadInput {
                document: Some(HexadDocumentInput {
                    title: format!("Multi-modal Document {}", i),
                    body: format!("Content about machine learning topic {}", i),
                    fields: HashMap::new(),
                }),
                vector: Some(embedding.into()),
                semantic: Some(vec!["https://example.org/Document".to_string()].into()),
                ..Default::default()
            };
            store.create(input).await.unwrap();
        }
    });

    group.throughput(Throughput::Elements(1000));

    group.bench_function("vector_similarity_search", |b| {
        let query = vec![0.5; 384];
        b.to_async(&rt).iter(|| async {
            black_box(store.search_similar(&query, 10, Some(0.8)).await.unwrap())
        });
    });

    group.bench_function("fulltext_search", |b| {
        b.to_async(&rt).iter(|| async {
            black_box(store.search_text("machine learning", 10).await.unwrap())
        });
    });

    group.finish();
    std::fs::remove_dir_all(&temp_dir).ok();
}

// ============================================================================
// Benchmark Groups
// ============================================================================

criterion_group!(
    document_benches,
    bench_document_create,
    bench_document_search
);

criterion_group!(
    vector_benches,
    bench_vector_insert,
    bench_vector_search
);

criterion_group!(
    graph_benches,
    bench_graph_operations
);

criterion_group!(
    hexad_benches,
    bench_hexad_operations
);

criterion_group!(
    drift_benches,
    bench_drift_detection
);

criterion_group!(
    cross_modal_benches,
    bench_cross_modal_query
);

criterion_main!(
    document_benches,
    vector_benches,
    graph_benches,
    hexad_benches,
    drift_benches,
    cross_modal_benches
);
