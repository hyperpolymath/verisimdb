# CLAUDE.md - VeriSimDB AI Assistant Instructions

## Project Overview

VeriSimDB (Veridical Simulacrum Database) is a 6-core multimodal database with self-normalization. Each entity exists simultaneously across 6 modalities (Graph, Vector, Tensor, Semantic, Document, Temporal) with drift detection and automatic consistency maintenance.

## Machine-Readable Artefacts

The following files in `.machine_readable/` contain structured project metadata:
- `STATE.scm` - Current project state and progress
- `META.scm` - Architecture decisions and development practices
- `ECOSYSTEM.scm` - Position in the ecosystem and related projects

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Elixir Orchestration Layer                                 │
│    ├── VeriSim.EntityServer (GenServer per entity)          │
│    ├── VeriSim.DriftMonitor (drift detection coordinator)   │
│    ├── VeriSim.QueryRouter (distributes queries)            │
│    └── VeriSim.SchemaRegistry (type system coordinator)     │
│              ↓ HTTP                                         │
├─────────────────────────────────────────────────────────────┤
│  Rust Core (verisim-api)                                    │
│    ├── verisim-graph (Oxigraph RDF/Property Graph)          │
│    ├── verisim-vector (HNSW similarity search)              │
│    ├── verisim-tensor (ndarray/Burn tensors)                │
│    ├── verisim-semantic (CBOR proof blobs)                  │
│    ├── verisim-document (Tantivy full-text)                 │
│    ├── verisim-temporal (versioning/time-series)            │
│    ├── verisim-hexad (unified entity)                       │
│    ├── verisim-drift (drift detection)                      │
│    └── verisim-normalizer (self-normalization)              │
└─────────────────────────────────────────────────────────────┘
```

## Design Philosophy (Marr's Three Levels)

1. **Computational Level**: What problem are we solving?
   - Maintain cross-modal consistency across 6 representations of the same entity
   - Detect and repair drift before it causes data quality issues
   - Provide unified querying across all modalities

2. **Algorithmic Level**: How do we solve it?
   - Hexad entities: one ID, six synchronized stores
   - Drift detection with configurable thresholds
   - Self-normalization triggered by drift events
   - OTP supervision for fault tolerance

3. **Implementational Level**: How is it built?
   - Rust for performance-critical modality stores
   - Elixir/OTP for distributed coordination
   - HTTP API for communication
   - Prometheus metrics for observability

## Language Policy

### ALLOWED
- **Rust** - Core database engine, modality stores
- **Elixir** - OTP orchestration layer
- **SQL** - Query interface (future)

### BANNED
- Python - Use Rust instead
- Go - Use Rust instead
- Node.js - Use Elixir instead

## Build Commands

### Rust Core
```bash
cd rust-core
cargo build
cargo test
cargo clippy
```

### Elixir Orchestration
```bash
cd elixir-orchestration
mix deps.get
mix compile
mix test
```

### Full Build
```bash
# Rust first (Elixir depends on it at runtime)
cargo build --release

# Then Elixir
cd elixir-orchestration && mix compile
```

## Container Deployment

Use Podman (NOT Docker):
```bash
podman build -t verisimdb:latest -f container/Containerfile .
podman run -p 8080:8080 verisimdb:latest
```

## Key Concepts

### Hexad Entity
A Hexad is one entity with 6 synchronized representations:
- **Graph**: RDF triples and property graph edges
- **Vector**: Embedding for similarity search
- **Tensor**: Multi-dimensional numeric data
- **Semantic**: Type annotations and proof blobs
- **Document**: Full-text searchable content
- **Temporal**: Version history and time-series

### Drift Detection
Drift is measured as divergence between modalities:
- `semantic_vector_drift`: Embedding doesn't match semantic content
- `graph_document_drift`: Graph structure doesn't match document
- `temporal_consistency_drift`: Version history issues
- `tensor_drift`: Tensor representation diverged
- `schema_drift`: Type constraint violations
- `quality_drift`: Overall data quality

### Self-Normalization
When drift exceeds thresholds, the normalizer:
1. Identifies the most authoritative modality
2. Regenerates drifted modalities from it
3. Validates consistency
4. Updates all modalities atomically

## Code Patterns

### Creating a Hexad (Rust)
```rust
let input = HexadBuilder::new()
    .with_document("Title", "Body content")
    .with_embedding(vec![0.1, 0.2, ...])
    .with_types(vec!["http://example.org/Document"])
    .with_relationships(vec![("relates_to", "other-entity-id")])
    .build();

let hexad = store.create(input).await?;
```

### Entity Server (Elixir)
```elixir
# Start entity server
{:ok, _pid} = VeriSim.EntityServer.start_link("entity-123")

# Get state
{:ok, state} = VeriSim.EntityServer.get("entity-123")

# Update
{:ok, new_state} = VeriSim.EntityServer.update("entity-123", [
  {:modality, :vector, true}
])
```

## Testing

### Unit Tests
```bash
cargo test                    # Rust
mix test                      # Elixir
```

### Integration Tests
```bash
cargo test --test integration # Rust integration tests
mix test test/integration     # Elixir integration tests
```

## User Preferences

- **Container runtime**: Podman > Docker
- **Source hosting**: GitLab > GitHub
- **Package manager**: Cargo (Rust), Mix (Elixir)
- **No Python**: Use Rust for systems, Julia for data processing

## Repository Structure

```
verisimdb/
├── Cargo.toml                 # Workspace definition
├── rust-core/                 # Rust crates
│   ├── verisim-graph/
│   ├── verisim-vector/
│   ├── verisim-tensor/
│   ├── verisim-semantic/
│   ├── verisim-document/
│   ├── verisim-temporal/
│   ├── verisim-hexad/
│   ├── verisim-drift/
│   ├── verisim-normalizer/
│   └── verisim-api/
├── elixir-orchestration/      # Elixir/OTP layer
│   ├── lib/verisim/
│   ├── config/
│   └── mix.exs
├── container/                 # Containerfiles
├── docs/                      # Documentation
└── tests/                     # Integration tests
```
