;; SPDX-License-Identifier: AGPL-3.0-or-later
;; META.scm - VeriSimDB Architecture Decisions and Practices
;; Media-Type: application/vnd.meta+scm

(meta
  (version "1.0")

  (architecture-decisions
    (adr (id "adr-001")
      (status "accepted")
      (date "2026-01-16")
      (title "Six-modality Hexad architecture")
      (context "Need unified entity representation across graph, vector, tensor, semantic, document, and temporal modalities")
      (decision "Each entity (Hexad) exists in all 6 stores with a shared ID. Consistency maintained via drift detection and self-normalization")
      (consequences
        "+ Unified view of entities"
        "+ Can query any modality"
        "- Storage overhead (6x representations)"
        "- Complexity in maintaining consistency"))

    (adr (id "adr-002")
      (status "accepted")
      (date "2026-01-16")
      (title "Rust core + Elixir orchestration split")
      (context "Need both performance (data operations) and fault tolerance (coordination)")
      (decision "Rust handles all data storage and modality operations. Elixir/OTP handles distributed coordination, fault tolerance, and process management")
      (consequences
        "+ Best of both worlds"
        "+ Clear separation of concerns"
        "- Two languages to maintain"
        "- HTTP overhead between layers"))

    (adr (id "adr-003")
      (status "accepted")
      (date "2026-01-16")
      (title "Drift-based self-normalization")
      (context "Cross-modal consistency can degrade over time or due to partial updates")
      (decision "Continuously measure 'drift' between modalities. When drift exceeds thresholds, automatically trigger normalization to repair consistency")
      (consequences
        "+ Self-healing system"
        "+ Configurable thresholds"
        "- Normalization has overhead"
        "- Need to define 'authoritative' modality"))

    (adr (id "adr-004")
      (status "accepted")
      (date "2026-01-16")
      (title "Process-per-entity model in Elixir")
      (context "Need isolation and concurrency for entity operations")
      (decision "Each active entity gets its own GenServer process, managed by DynamicSupervisor")
      (consequences
        "+ Entity failures are isolated"
        "+ Concurrent entity operations"
        "+ Natural fit for OTP"
        "- Memory overhead per entity"
        "- Need lifecycle management"))

    (adr (id "adr-005")
      (status "accepted")
      (date "2026-01-16")
      (title "Marr's three levels as design guide")
      (context "Need consistent design philosophy across the system")
      (decision "Use David Marr's three levels (Computational, Algorithmic, Implementational) to guide design decisions")
      (consequences
        "+ Clear separation of what/how/implementation"
        "+ Better documentation"
        "+ Easier to reason about changes")))

  (development-practices
    (code-style
      (rust
        (formatter "rustfmt")
        (linter "clippy")
        (edition "2024")
        (pattern "error handling via thiserror/anyhow"))
      (elixir
        (formatter "mix format")
        (linter "credo")
        (pattern "GenServer for stateful processes")
        (pattern "Telemetry for metrics")))

    (security
      (principle "No secrets in code")
      (principle "Environment variables for config")
      (principle "CBOR proofs for semantic claims"))

    (testing
      (rust "proptest for property-based testing")
      (elixir "ExUnit with mocks via Mox")
      (integration "End-to-end tests with real stores"))

    (versioning
      (scheme "SemVer")
      (changelog "CHANGELOG.md"))

    (documentation
      (rust "rustdoc with examples")
      (elixir "ExDoc with doctests")
      (architecture "docs/ directory"))

    (branching
      (main "stable, releasable")
      (develop "integration branch")
      (feature "feature/description")))

  (design-rationale
    (why-six-modalities
      "Graph: Relationships and structure"
      "Vector: Similarity and semantic proximity"
      "Tensor: Numeric and ML operations"
      "Semantic: Type system and proofs"
      "Document: Human-readable text"
      "Temporal: History and time-travel")

    (why-rust-for-core
      "Performance: Data operations need to be fast"
      "Memory safety: No GC pauses in hot path"
      "Type system: Catches errors at compile time"
      "Ecosystem: Great crates for each modality")

    (why-elixir-for-orchestration
      "OTP: Battle-tested supervision trees"
      "Fault tolerance: Let it crash philosophy"
      "Concurrency: Lightweight processes"
      "Distribution: Built-in clustering")))
