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
- **ReScript** - VQL parser, federation registry
- **VQL** - VeriSim Query Language (native query interface, NOT SQL)

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

## GitHub CI Integration (Priority - Sonnet Task)

VeriSimDB needs to service all ~290 hyperpolymath repos from GitHub Actions CI.

### Architecture: Git-Backed Flat-File Store

Instead of running verisimdb as a persistent server in GitHub, use a **git-backed data repo**:

```
hyperpolymath/verisimdb-data (new repo)
├── scans/                    # panic-attack scan results per repo
│   ├── echidna.json
│   ├── verisimdb.json
│   └── ...
├── hardware/                 # hardware-crash-team findings
│   └── latest-scan.json
├── drift/                    # drift detection snapshots
│   └── drift-status.json
├── index.json                # Master index of all hexads
└── .github/workflows/
    └── ingest.yml            # Workflow: receive data, update index
```

### How It Works

1. **Each repo's CI** runs panic-attack, produces JSON, pushes to `verisimdb-data` via workflow dispatch
2. **verisimdb-data ingest workflow** receives the JSON, stores it, updates the index
3. **Query** by checking out verisimdb-data and reading JSON (no server needed)
4. **Local dev**: Run `verisim-api` server locally, load from the data repo

### Implementation Steps (for Sonnet)

1. Create `verisimdb-data` repo from rsr-template-repo
2. Add `ingest.yml` workflow that accepts repository_dispatch events with scan payloads
3. Add a reusable workflow `scan-and-report.yml` that repos can call:
   - Runs `panic-attack assail` on the repo
   - Sends results to verisimdb-data via repository_dispatch
4. Add the reusable workflow to 2-3 pilot repos first (echidna, panic-attacker, ambientops)
5. Add a `query.sh` script that clones verisimdb-data and searches the index

### Future: Persistent Server

When ready to scale beyond flat files:
- Deploy verisim-api to **Fly.io free tier** (3 shared VMs, 1GB persistent volume)
- Use the Containerfile already in `container/`
- GitHub Actions calls the Fly.io endpoint instead of repository_dispatch
- Keep verisimdb-data as backup/mirror

## Hypatia Integration Pipeline (Priority - Sonnet Task)

### Data Flow (NOT YET IMPLEMENTED)

```
panic-attack assail → verisimdb hexads → hypatia rules → gitbot-fleet
                      ↑ WORKS            ↑ BUILD THIS   ↑ BUILD THIS
```

### What Needs Building

1. **verisimdb → hypatia connector**: Hypatia needs a Logtalk rule that queries verisimdb-data
   - Read scan results from verisimdb-data repo (or API)
   - Transform weak points into Logtalk facts
   - Fire rules to detect patterns (e.g., "3+ repos have same unsafe pattern")

2. **hypatia → gitbot-fleet dispatcher**: When hypatia detects actionable patterns
   - sustainabot: receives EcoScore/EconScore metrics from scan results
   - echidnabot: receives proof obligations ("verify this fix resolves these weak points")
   - rhodibot: receives automated fix suggestions

3. **Hexad schema for scan results**:
   ```rust
   // Document modality: full JSON report as searchable text
   // Graph modality: file -> weakness -> recommendation triples
   // Temporal modality: track results over time (drift detection)
   // Vector modality: embed weakness descriptions for similarity search
   ```

## Model Router (Future Tool - Sonnet Task)

A tool to auto-select Claude model based on task complexity. Architecture:

```
User prompt → Haiku classifier → Route to:
  ├── Haiku:  single-file edits, template creation, simple queries
  ├── Sonnet: multi-file implementation, feature work, testing
  └── Opus:   architecture decisions, debugging, cross-repo design
```

### Classification Signals
- File count affected (1 = Haiku, 2-5 = Sonnet, 5+ = Opus)
- Task type (create = Sonnet, debug = Opus, edit = Haiku)
- CLAUDE.md complexity rating per repo
- Presence of "why", "how", "design" in prompt → Opus
- Presence of "add", "create", "implement" → Sonnet
- Presence of "fix typo", "rename", "update version" → Haiku

### Implementation
- Rust CLI tool or Claude Code hook
- Reads CLAUDE.md to understand repo complexity
- Uses Haiku API call (~0.001 cents) to classify
- Returns recommended model as stdout

## Known Issues

See `KNOWN-ISSUES.adoc` at repo root for all honest gaps. Key items:
1. Normalizer regeneration strategies are stubs
2. Federation executor returns empty results
3. GQL-DT not connected to VQL PROOF clause
4. ZKP/proven library not integrated
5. ReScript registry ~60% complete

## Hypatia Integration Status

**Working:**
- Hypatia VQL layer reads verisimdb-data flat files directly
- Built-in Elixir VQL parser (no external Deno/Node needed)
- 954 canonical patterns tracked across 298 repos
- Cross-repo analytics: `pipeline_health/0`, `cross_repo_patterns/1`, `category_distribution/0`

**Needs PAT:** Automated cross-repo dispatch requires a GitHub PAT with `repo` scope.
See `verisimdb-data/INTEGRATION.md` for PAT setup instructions.

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
