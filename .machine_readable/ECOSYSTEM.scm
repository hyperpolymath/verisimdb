;; SPDX-License-Identifier: PMPL-1.0-or-later
;; Media type: application/vnd.ecosystem+scm

(ecosystem
  (version "1.0.0")
  (name "verisimdb")
  (type "database-system")
  (purpose "Multimodal federated database with drift-tolerant coordination, zero-knowledge proofs, and six data modalities (Graph, Vector, Tensor, Semantic, Document, Temporal)")

  (position-in-ecosystem
    (layer "infrastructure")
    (role "core-database")
    (dependencies-on ["oxigraph" "hnsw" "tantivy" "proven" "sactify-php"])
    (provides-to ["researchers" "ai-systems" "knowledge-workers" "federated-institutions"]))

  (related-projects
    (sibling-standard
      (project "verisimdb-debugger")
      (relationship "provides-observability-for")
      (url "https://github.com/hyperpolymath/verisimdb-debugger")
      (rationale "VeriSimDB Debugger (v2) is a separate TUI tool for tracing queries, visualizing drift, and inspecting ZKP proofs. It connects to VeriSimDB instances via API."))

    (potential-consumer
      (project "vql-language-server")
      (relationship "could-provide-ide-integration")
      (url "https://github.com/hyperpolymath/vql-language-server")
      (rationale "Future Language Server Protocol implementation for VQL, providing IDE features like autocomplete, diagnostics, and inline documentation."))

    (potential-consumer
      (project "hypatia")
      (relationship "could-use-for-storage")
      (url "https://github.com/hyperpolymath/hypatia")
      (rationale "Hypatia research assistant could leverage VeriSimDB's multimodal storage for citations (graph), embeddings (vector), and semantic relationships."))

    (dependency
      (project "oxigraph")
      (relationship "uses-for-graph-store")
      (url "https://github.com/oxigraph/oxigraph")
      (rationale "Oxigraph provides RDF/SPARQL support for the graph modality store (verisim-graph)."))

    (dependency
      (project "proven")
      (relationship "uses-for-zkp")
      (url "https://github.com/proven-network/proven")
      (rationale "Proven library provides zero-knowledge proof generation and verification for VQL queries with PROOF clauses."))

    (dependency
      (project "sactify-php")
      (relationship "uses-for-federation-signatures")
      (url "https://github.com/hyperpolymath/sactify-php")
      (rationale "Sactify provides cryptographic signatures for federation store registration and Byzantine fault tolerance."))

    (inspiration
      (project "datomic")
      (relationship "architectural-inspiration")
      (url "https://www.datomic.com")
      (rationale "Datomic's immutable temporal log and separation of storage/query influenced VeriSimDB's temporal modality and hexad architecture."))

    (inspiration
      (project "apache-kafka")
      (relationship "architectural-inspiration")
      (url "https://kafka.apache.org")
      (rationale "KRaft (Kafka without ZooKeeper) inspired VeriSimDB's federated registry design with metadata quorum and Raft consensus."))

    (related-standard
      (project "fair-principles")
      (relationship "implements")
      (url "https://www.go-fair.org/fair-principles/")
      (rationale "VeriSimDB implements FAIR principles (Findable, Accessible, Interoperable, Reusable) through ZKP proofs, federation, and semantic types.")))

  (what-this-is
    "VeriSimDB is a multimodal federated database designed for research, AI, and knowledge work. It provides:\n  - Six modalities in one namespace: Graph (citations), Vector (embeddings), Tensor (model weights), Semantic (types), Document (text), Temporal (versions)\n  - Drift-tolerant federation: Detect and repair inconsistencies across federated stores without blocking availability\n  - VQL (VeriSim Query Language): Unified query language with dependent types for formal verification (PROOF path) and simple types for performance (slipstream path)\n  - Zero-knowledge proofs: Verifiable query results without exposing private data (GDPR, HIPAA, FAIR compliance)\n  - Tiny core (<5k LOC): Operates as standalone database OR federated coordinator without rewrite\n  - Adaptive learning: System self-tunes cache TTL, normalization policies, and query strategies based on workload\n\nTarget users: Researchers (citation networks), AI engineers (embeddings + model weights), institutions (federated privacy-preserving data sharing).")

  (what-this-is-not
    "- NOT a traditional relational database (use PostgreSQL for that)\n- NOT a pure graph database (use Neo4j if you only need graphs)\n- NOT a pure vector database (use Pinecone/Weaviate if you only need embeddings)\n- NOT a document store with full-text search only (use Elasticsearch for that)\n- NOT a blockchain (immutable log ≠ distributed ledger)\n- NOT a data lake (VeriSimDB enforces types and semantics)\n- NOT a message queue (though temporal store provides event log)\n- NOT an ETL tool (VeriSimDB eliminates need for ETL between modalities)\n- NOT a single-language system (uses ReScript, Elixir, Rust for different components)\n- NOT production-ready yet (v0.1.0-alpha, ~88% complete, security-hardened)"))
