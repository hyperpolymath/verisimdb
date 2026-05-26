;; SPDX-License-Identifier: MPL-2.0
;; Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
;;
;; ECOSYSTEM.scm — VeriSimDB's position in the hyperpolymath ecosystem
;; and the wider software-engineering landscape.

(ecosystem
 (project "verisimdb")
 (snapshot-date "2026-05-26")

 (hyperpolymath-estate
  ;; Repos VeriSimDB depends on or is depended-by within the org.
  (dependencies
   (standards
    :role "Shared governance workflows (governance-reusable.yml). Estate-wide language-policy enforcement, security policy, well-known checks."
    :uri "https://github.com/hyperpolymath/standards")
   (rsr-template-repo
    :role "Repository template — taxonomy reference (top-level files, docs/ subtree, machine-readable layout)."
    :uri "https://github.com/hyperpolymath/rsr-template-repo")
   (palimpsest-license
    :role "License vendor.  Project ships under MPL-2.0 but participates in the Palimpsest ecosystem."
    :uri "https://github.com/hyperpolymath/palimpsest-license"))

  (provides-to
   ;; What other hyperpolymath repos consume from VeriSimDB.
   (hypatia
    :consumption "Drift detection results, panic-attack scan ingestion"
    :integration-modules
    ("elixir-orchestration/lib/verisim/hypatia/scan_ingester.ex"
     "elixir-orchestration/lib/verisim/hypatia/pattern_query.ex"
     "elixir-orchestration/lib/verisim/hypatia/dispatch_bridge.ex"))
   (panll
    :consumption "Telemetry dashboard panels (modality heatmap, query patterns, performance metrics)"
    :integration "Product telemetry collector + reporter via VeriSim.Telemetry")
   (verisimdb-data
    :consumption "Git-backed flat-file CI store (planned, not yet built — see CLAUDE.md priority section)"
    :status :planned)))

 (sibling-databases-in-ecosystem
  ;; Other databases hyperpolymath maintains, referenced via PanLL DatabaseRegistry.
  (verisimdb
   :role "Veridical octad storage, drift detection, federation"
   :modalities 8)
  (quandledb
   :role "Quandle-based knowledge graph"
   :pulled-via "PanLL DatabaseRegistry")
  (lithoglyph
   :role "Append-only event log"
   :pulled-via "PanLL DatabaseRegistry"))

 (third-party-stack
  ;; External libraries we depend on materially.
  (rust
   (oxigraph "RDF/property graph, optional via feature flag")
   (hnsw_rs "vector ANN")
   (ndarray "tensor")
   (burn "tensor ML")
   (tantivy "full-text")
   (redb "persistent kv (pure Rust B-tree, ACID)")
   (axum "HTTP server")
   (tokio "async runtime")
   (rustls "TLS (no OpenSSL)")
   (sha2 "ZKP hash primitives")
   (criterion "benchmarks")
   (proptest "property tests")
   (insta "snapshot tests")
   (cargo-mutants "mutation testing"))
  (elixir
   (bandit "HTTP server")
   (plug "HTTP middleware")
   (req "HTTP client")
   (jason "JSON")
   (telemetry "metrics + events")
   (horde "distributed registry")
   (postgrex redix exqlite bolt_sips "federation adapters")
   (stream_data "property tests")
   (excoveralls "coverage")
   (benchee "benchmarks")
   (mox "mocking"))
  (rescript
   (rescript "language")
   ("@rescript/core" "stdlib")))

 (academic-anchors
  ;; Papers / specs that ground the design.
  (vql-spec "ISO/IEC 14977 EBNF grammar, formal semantics, dependent type system")
  (drift-detection "Marr's three levels applied to data drift; consultation paper in docs/")
  (zkp-integration "sanctify library bridge + R1CS circuit compilation")
  (federation "VeriSimDB Federated Consistency paper — docs/papers/")
  (papers-dir "docs/papers/"))

 (open-source-comparators
  ;; What VeriSimDB sits next to in the broader landscape (for
  ;; positioning, not direct competition — most are single-modality).
  (multi-modal
   (weaviate :modalities "vector + GraphQL")
   (vespa :modalities "vector + graph + full-text + tensor")
   (typedb :modalities "graph + symbolic + temporal"))
  (specialised
   (oxigraph "graph (RDF) — used by us as a backend")
   (qdrant milvus pinecone "vector")
   (clickhouse "columnar OLAP")
   (timescaledb influxdb "time-series")
   (postgis "spatial"))
  (verisimdb-position
   "Native polyglot: every entity exists in ALL 8 modalities simultaneously,
    with cross-modal consistency maintained automatically.  Not a federation
    over single-modality DBs (we do that too via connectors/), but a
    primary store.  No direct apples-to-apples comparator.")))
