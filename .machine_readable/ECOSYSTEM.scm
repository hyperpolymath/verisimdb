;; SPDX-License-Identifier: AGPL-3.0-or-later
;; ECOSYSTEM.scm - VeriSimDB Position in Ecosystem
;; Media-Type: application/vnd.ecosystem+scm

(ecosystem
  (version "1.0")
  (name "VeriSimDB")
  (type "database")
  (purpose "6-core multimodal database with self-normalization and drift detection")

  (position-in-ecosystem
    (category "data-storage")
    (subcategory "multimodal-databases")
    (unique-value
      "Unified 6-modality representation (Hexad)"
      "Automatic drift detection and self-normalization"
      "Marr's three levels design philosophy"
      "Rust performance + Elixir fault tolerance"))

  (related-projects
    (sibling-standard
      (project "formbd")
      (relationship "sibling-standard")
      (description "Narrative-first audit-grade database")
      (synergy "Both explore novel database architectures; FormBD focuses on auditability, VeriSimDB on multimodality"))

    (sibling-standard
      (project "formbd-geo")
      (relationship "sibling-standard")
      (description "Geospatial projection layer for FormBD")
      (synergy "Similar projection-layer architecture; VeriSimDB internalizes all modalities"))

    (sibling-standard
      (project "formbd-analytics")
      (relationship "sibling-standard")
      (description "OLAP analytics projection layer for FormBD")
      (synergy "VeriSimDB's tensor modality provides similar OLAP capabilities internally"))

    (inspiration
      (project "qdrant")
      (relationship "inspiration")
      (description "Vector database for similarity search")
      (differentiation "VeriSimDB integrates vector search as one of six modalities, not standalone"))

    (inspiration
      (project "neo4j")
      (relationship "inspiration")
      (description "Graph database")
      (differentiation "VeriSimDB's graph modality is one component of unified multimodal storage"))

    (inspiration
      (project "elasticsearch")
      (relationship "inspiration")
      (description "Full-text search engine")
      (differentiation "VeriSimDB's document modality provides search alongside other modalities"))

    (inspiration
      (project "datomic")
      (relationship "inspiration")
      (description "Immutable database with time-based queries")
      (differentiation "VeriSimDB's temporal modality provides versioning with 5 other modalities"))

    (potential-consumer
      (project "anamnesis")
      (relationship "potential-consumer")
      (description "Conversation knowledge extraction")
      (synergy "VeriSimDB could store extracted knowledge with full multimodal representation"))

    (potential-consumer
      (project "bofig")
      (relationship "potential-consumer")
      (description "Boundary objects and epistemological scoring")
      (synergy "VeriSimDB semantic modality with proofs fits PROMPT scoring storage")))

  (what-this-is
    "A database where each entity has 6 synchronized representations"
    "A self-healing system that detects and repairs cross-modal drift"
    "A Rust core with Elixir orchestration for performance + fault tolerance"
    "An implementation of Marr's three levels design philosophy"
    "A foundation for AI systems needing multimodal knowledge")

  (what-this-is-not
    "A drop-in replacement for PostgreSQL or MySQL"
    "A standalone vector database (see Qdrant)"
    "A standalone graph database (see Neo4j)"
    "A distributed database (orchestration layer handles distribution)"
    "A time-series database (temporal is one modality of six)"))
