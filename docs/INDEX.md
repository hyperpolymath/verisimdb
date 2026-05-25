# VeriSimDB Documentation Index

> Last updated: 2026-05-25. This file is the table of contents for everything under `docs/` and the top-level project documents.

## Top-level (repository root)

The repo root holds only documents that need maximum visibility for new readers, plus the artefacts the RSR template requires.

| File | Purpose |
|---|---|
| [README.adoc](../README.adoc) | Project entry point — what VeriSimDB is, how to install/run, where to look next |
| [ROADMAP.md](../ROADMAP.md) | Criticality-ordered work plan (Phase 1–8) |
| [CHANGELOG.adoc](../CHANGELOG.adoc) | Versioned history of all notable changes |
| [TESTING.md](../TESTING.md) | Testing & benchmarking standards (hard CI gates per language, property-test patterns, fuzz corpus location) |
| [KNOWN-ISSUES.adoc](../KNOWN-ISSUES.adoc) | Honest-gaps audit trail — all 25 catalogued issues with resolution status |
| [AUDIT.adoc](../AUDIT.adoc) | RSR audit-index pointing to KNOWN-ISSUES, TESTING, SECURITY, CHANGELOG |
| [SECURITY.md](../SECURITY.md) | Threat model, disclosure process, supported versions |
| [CONTRIBUTING.md](../CONTRIBUTING.md) | How to propose changes, run gates locally |
| [MAINTAINERS.adoc](../MAINTAINERS.adoc) | Active maintainers |
| [CODE_OF_CONDUCT.md](../CODE_OF_CONDUCT.md) | Community standards |
| [LICENSE](../LICENSE) | MPL-2.0 |
| [0-AI-MANIFEST.a2ml](../0-AI-MANIFEST.a2ml) | AI manifest for the project |
| [justfile](../justfile) | Task definitions for the `just` runner |

## docs/ tree

### Architecture

- [docs/architecture/abi-ffi.md](architecture/abi-ffi.md) — ABI/FFI contract for cross-language calls (Rust ↔ Elixir ↔ Idris2)
- [docs/architecture/topology.md](architecture/topology.md) — Process topology and deployment shapes

### Decisions (ADR-style)

- [docs/decisions/rust-spark-stance.adoc](decisions/rust-spark-stance.adoc) — Why Rust over alternatives for the core
- [docs/decisions/kraft-comparison.adoc](decisions/kraft-comparison.adoc) — Why KRaft for the consensus layer
- [docs/decisions/proven-coherence.md](decisions/proven-coherence.md) — Notes on the proven library integration

### Deployment

- [docs/deployment/deployment.adoc](deployment/deployment.adoc) — Full deployment guide (Podman, selur-compose, Containerfile)
- [docs/deployment/void-setup.md](deployment/void-setup.md) — Void Linux dev environment setup

### Status & implementation tracking

- [docs/status/planner.md](status/planner.md) — verisim-planner implementation status
- [docs/status/implementation-plan.adoc](status/implementation-plan.adoc) — Original timeline-based execution plan (V1–V5)

### Releases

- [docs/releases/v0.1.0-alpha.md](releases/v0.1.0-alpha.md) — Narrative release announcement for v0.1.0-alpha (2026-02-04)

### Papers & whitepaper

- [docs/papers/whitepaper.md](papers/whitepaper.md) — VeriSimDB whitepaper (Markdown source)
- [docs/papers/whitepaper.pdf](papers/whitepaper.pdf) — Whitepaper PDF artefact
- [docs/papers/arcvix-octad-data-model.tex](papers/arcvix-octad-data-model.tex) — ARCVIX octad data-model paper (LaTeX)
- [docs/papers/references.bib](papers/references.bib) — BibTeX references for the papers
- [docs/papers/verisimdb-federated-consistency.adoc](papers/verisimdb-federated-consistency.adoc) — Federated consistency paper
- [docs/papers/verisimdb-idaptik-case-study.adoc](papers/verisimdb-idaptik-case-study.adoc) — Idaptik case study

### Visualizations

- [docs/visualizations/architecture.html](visualizations/architecture.html) — Interactive architecture diagram
- [docs/visualizations/historiographic-custodian.html](visualizations/historiographic-custodian.html) — Historiographic custodian visualization

### Business

- [docs/business/business-case.adoc](business/business-case.adoc) — Business case for VeriSimDB
- [docs/business/financials/](business/financials/) — Financial models
- [docs/business/marketing/](business/marketing/) — Marketing materials
- [docs/business/pr/](business/pr/) — Press releases
- [docs/business/strategy/](business/strategy/) — Strategic planning

### Design notes (dated, point-in-time)

- [docs/design/DESIGN-2026-02-27-level-data-model.md](design/DESIGN-2026-02-27-level-data-model.md)
- [docs/design/DESIGN-2026-02-27-strategic-improvements.adoc](design/DESIGN-2026-02-27-strategic-improvements.adoc)
- [docs/design/DESIGN-2026-02-27-vql-dt-assessment.adoc](design/DESIGN-2026-02-27-vql-dt-assessment.adoc)
- [docs/design/DESIGN-2026-02-28-panll-interop-telemetry.md](design/DESIGN-2026-02-28-panll-interop-telemetry.md)

### VQL language

- [docs/getting-started.adoc](getting-started.adoc) — VQL getting started
- [docs/VQL-SPEC.adoc](VQL-SPEC.adoc) — Full VQL specification
- [docs/vql-grammar.ebnf](vql-grammar.ebnf) — ISO/IEC 14977 EBNF grammar
- [docs/vql-architecture.adoc](vql-architecture.adoc) — Parser / executor architecture
- [docs/vql-type-system.adoc](vql-type-system.adoc) — VQL-DT dependent type system
- [docs/vql-formal-semantics.adoc](vql-formal-semantics.adoc) — Formal semantics
- [docs/vql-examples.adoc](vql-examples.adoc) — Worked examples
- [docs/vql-vs-vql-dt.adoc](vql-vs-vql-dt.adoc) — VQL vs VQL-DT comparison
- [docs/vql-vs-sql.adoc](vql-vs-sql.adoc) — VQL vs SQL comparison
- [docs/rescript-registry-types.adoc](rescript-registry-types.adoc) — ReScript registry types

### Operational concerns

- [docs/deployment-modes.adoc](deployment-modes.adoc) — Standalone vs federated vs hybrid
- [docs/error-handling-strategy.adoc](error-handling-strategy.adoc) — Error taxonomy
- [docs/safety-and-fault-tolerance.adoc](safety-and-fault-tolerance.adoc) — Supervision, retry, circuit breakers
- [docs/safety-theory-applied.adoc](safety-theory-applied.adoc) — Safety theory grounding
- [docs/security-lessons.lgt](security-lessons.lgt) — Security retrospective (Logtalk)
- [docs/caching-strategy.adoc](caching-strategy.adoc) — Cache invalidation strategy
- [docs/cache-sharing-strategy.adoc](cache-sharing-strategy.adoc) — Cross-process cache sharing
- [docs/snapshotting-and-truncation-logic.adoc](snapshotting-and-truncation-logic.adoc) — WAL snapshots
- [docs/normalization-cascade.adoc](normalization-cascade.adoc) — Drift normalization cascade
- [docs/drift-handling.adoc](drift-handling.adoc) — Drift detection and remediation
- [docs/reversibility-design.adoc](reversibility-design.adoc) — Reversibility/audit guarantees
- [docs/backwards-compatibility.adoc](backwards-compatibility.adoc) — Backwards compatibility policy
- [docs/adoption-strategy.adoc](adoption-strategy.adoc) — Adoption strategy
- [docs/federation-readiness.adoc](federation-readiness.adoc) — Federation readiness checklist
- [docs/challenges-standalone.adoc](challenges-standalone.adoc) — Standalone deployment challenges
- [docs/challenges-federated.adoc](challenges-federated.adoc) — Federated deployment challenges
- [docs/challenges-hybrid.adoc](challenges-hybrid.adoc) — Hybrid mode challenges

### Specialized

- [docs/consultation-dependent-types-zkp.adoc](consultation-dependent-types-zkp.adoc) — Consultation paper: dependent types + ZKP
- [docs/consultation-normalization-strategy.adoc](consultation-normalization-strategy.adoc) — Consultation paper: normalization
- [docs/zkp-and-sanctify-integration.adoc](zkp-and-sanctify-integration.adoc) — ZKP + sanctify integration design (now implemented — see KNOWN-ISSUES #6)
- [docs/query-optimization-overview.adoc](query-optimization-overview.adoc) — Query optimizer overview
- [docs/technical-specification-kraft-metadata-log.adoc](technical-specification-kraft-metadata-log.adoc) — KRaft metadata log spec
- [docs/minikanren-integration-v3.adoc](minikanren-integration-v3.adoc) — miniKanren integration v3
- [docs/panll-module-audit.adoc](panll-module-audit.adoc) — PanLL module audit
- [docs/rsr-compliance.adoc](rsr-compliance.adoc) — RSR template compliance notes
- [docs/CITATIONS.adoc](CITATIONS.adoc) — Bibliographic citations for the project

## Machine-readable artefacts

Under [`.machine_readable/`](../.machine_readable/):

- `STATE.scm` — current project state and progress
- `META.scm` — architecture decisions and development practices
- `ECOSYSTEM.scm` — position in the ecosystem and related projects

## Workflow & CI

Under [`.github/workflows/`](../.github/workflows/):

- `rust-ci.yml` — fmt, clippy, test, doc, audit, deny, bench-compile, fuzz-compile, coverage
- `elixir-ci.yml` — format, compile (`--warnings-as-errors`), test, hex.audit, coverage, bench-compile
- `governance.yml` — estate-wide governance bundle (workflow security, language anti-patterns, etc.)
- `codeql.yml` — CodeQL security analysis
- `cflite_batch.yml`, `cflite_pr.yml` — ClusterFuzzLite (PR and batch fuzzing)
- `secret-scanner.yml` — TruffleHog + Gitleaks
- `scorecard.yml`, `scorecard-enforcer.yml` — OpenSSF Scorecard
- `spark-theatre-gate.yml` — SPARK Theatre Gate
- `hypatia-scan.yml` — Hypatia neurosymbolic analysis
- `instant-sync.yml`, `mirror.yml` — mirror sync workflows
- `jekyll-gh-pages.yml` — GitHub Pages deployment

## Source code

| Path | Language | Purpose |
|---|---|---|
| `rust-core/` | Rust | Core database engine (8 modality stores + octad + drift + normalizer + api + planner) |
| `elixir-orchestration/` | Elixir | OTP orchestration layer (DriftMonitor, EntityServer, VQLExecutor, VQLBridge, SchemaRegistry, federation adapters) |
| `src/` | ReScript | VQL parser, type checker, federation registry |
| `playground/` | ReScript + HTML | VQL Playground web UI |
| `connectors/` | Multi | Federation adapters, client SDKs (Rust, V, Elixir, ReScript, Julia, Gleam), test infrastructure |
| `debugger/` | Idris2 + Rust | ABI/FFI debugger |
| `ffi/zig/` | Zig | Zig FFI |
| `v-api-gateway/` | V | V-language API gateway |
| `fuzz/`, `rust-core/fuzz/` | Rust | Fuzz harnesses (libFuzzer via cargo-fuzz) |
| `benches/` | Rust | Criterion benchmarks (all 8 modalities + cross-modal + octad + drift) |
| `elixir-orchestration/bench/` | Elixir | Benchee benchmark scripts (DriftMonitor, QueryRouter, VQLExecutor, VQLBridge, SchemaRegistry) |

## Container & deployment

- [`container/`](../container/) — Containerfile, ct-build.sh, compose.toml, manifest.toml, .gatekeeper.yaml
- [`.clusterfuzzlite/`](../.clusterfuzzlite/) — Dockerfile + build.sh for ClusterFuzzLite
- [`selur-compose.yml`](../selur-compose.yml) — selur-compose stack definition
- [`stapeln.toml`](../stapeln.toml) — stapeln supply-chain config
- [`opsm.toml`](../opsm.toml) — operations manifest
