;; SPDX-License-Identifier: AGPL-3.0-or-later
;; STATE.scm - VeriSimDB Project State
;; Media-Type: application/vnd.state+scm

(state
  (metadata
    (version "1.0")
    (schema-version "1.0")
    (created "2026-01-16")
    (updated "2026-01-16")
    (project "verisimdb")
    (repo "gitlab.com/hyperpolymath/verisimdb"))

  (project-context
    (name "VeriSimDB")
    (tagline "The Veridical Simulacrum Database - 6-core multimodal with self-normalization")
    (tech-stack
      (rust "Core database engine, modality stores")
      (elixir "OTP orchestration layer")
      (axum "HTTP API framework")
      (oxigraph "RDF/Graph store")
      (tantivy "Full-text search")
      (hnsw "Vector similarity")))

  (current-position
    (phase "bootstrap")
    (overall-completion 5)
    (components
      (rust-core
        (completion 10)
        (status "skeleton")
        (crates
          (verisim-graph "skeleton - Oxigraph integration")
          (verisim-vector "skeleton - HNSW store")
          (verisim-tensor "skeleton - ndarray ops")
          (verisim-semantic "skeleton - CBOR proofs")
          (verisim-document "skeleton - Tantivy search")
          (verisim-temporal "skeleton - versioning")
          (verisim-hexad "skeleton - unified entity")
          (verisim-drift "skeleton - drift detection")
          (verisim-normalizer "skeleton - self-normalization")
          (verisim-api "skeleton - HTTP API")))
      (elixir-orchestration
        (completion 10)
        (status "skeleton")
        (modules
          (entity-server "GenServer per entity")
          (drift-monitor "Drift coordination")
          (query-router "Query distribution")
          (schema-registry "Type management")
          (rust-client "HTTP client to Rust core"))))
    (working-features
      "Project structure created"
      "Cargo workspace configured"
      "Mix project configured"
      "Basic module skeletons"))

  (route-to-mvp
    (milestone (id "M1") (name "Core Modality Stores")
      (items
        (item "verisim-graph: Basic insert/query" status: pending)
        (item "verisim-vector: Basic HNSW operations" status: pending)
        (item "verisim-document: Basic full-text search" status: pending)
        (item "verisim-temporal: Version tracking" status: pending)))

    (milestone (id "M2") (name "Hexad Integration")
      (items
        (item "Hexad entity creation across modalities" status: pending)
        (item "Cross-modal consistency checks" status: pending)
        (item "Unified query interface" status: pending)))

    (milestone (id "M3") (name "Drift Detection")
      (items
        (item "Drift scoring algorithms" status: pending)
        (item "Threshold configuration" status: pending)
        (item "Drift event notifications" status: pending)))

    (milestone (id "M4") (name "Self-Normalization")
      (items
        (item "Normalization strategies" status: pending)
        (item "Automatic drift repair" status: pending)
        (item "Normalization metrics" status: pending)))

    (milestone (id "M5") (name "HTTP API")
      (items
        (item "CRUD endpoints for Hexads" status: pending)
        (item "Search endpoints" status: pending)
        (item "Drift/normalization endpoints" status: pending)))

    (milestone (id "M6") (name "Elixir Orchestration")
      (items
        (item "Entity server lifecycle" status: pending)
        (item "Drift monitor coordination" status: pending)
        (item "Query routing" status: pending))))

  (blockers-and-issues
    (critical)
    (high)
    (medium
      (issue "Need to verify Rust edition 2024 compatibility")
      (issue "HNSW crate version compatibility check needed"))
    (low))

  (critical-next-actions
    (immediate
      "Verify Rust workspace compiles"
      "Run cargo check on all crates")
    (this-week
      "Implement basic graph store operations"
      "Implement basic vector store operations")
    (this-month
      "Complete M1 modality stores"
      "Begin Hexad integration")))
