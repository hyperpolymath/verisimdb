;; SPDX-License-Identifier: MPL-2.0
;; Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
;;
;; META.scm — architecture decisions and development practices.
;;
;; Stable across releases; updated when an architecture decision is taken
;; or revised.  Each entry includes the rationale so reviewers can
;; reconstruct intent.

(meta
 (project "verisimdb")
 (snapshot-date "2026-05-26")

 (design-philosophy
  ;; Marr's three levels of analysis applied to the project.
  (computational
   :goal "Maintain cross-modal consistency across 8 representations of the same entity (octad)."
   :sub-goals
   ("Detect and repair drift before it causes downstream failures"
    "Provide unified querying across all modalities"
    "Federate over heterogeneous existing databases"))
  (algorithmic
   :approach
   ("Octad entities: one ID, eight synchronized stores"
    "Drift detection with configurable thresholds"
    "Self-normalization triggered by drift events"
    "OTP supervision for fault tolerance"))
  (implementational
   :stack
   ("Rust for performance-critical modality stores"
    "Elixir/OTP for distributed coordination"
    "HTTP API for cross-language communication"
    "Prometheus metrics for observability")))

 (language-policy
  (allowed
   (rust "core database engine, modality stores")
   (elixir "OTP orchestration layer")
   (rescript "VQL parser, federation registry, ABI bridge, playground")
   (idris2 "ABI debugger, formal verification proofs")
   (vql "native query interface — NOT SQL")
   (v "API gateway")
   (zig "FFI shim")
   (julia "client SDK"))
  (banned
   (python "use Rust for systems, Julia for data processing — exception for SaltStack")
   (go "use Rust instead")
   (nodejs "use Elixir instead"))
  (exemption-mechanism ".hypatia-ignore for whitelisted ReScript files; ReScript is allowed but governance scans for it estate-wide"))

 (testing-pyramid
  ;; Adopted from Google's 70/20/10 baseline, adjusted for our
  ;; polyglot DB architecture (federation pulls integration ratio up).
  (rust-unit 70)            ; %; #[cfg(test)] mod tests in source files
  (cross-language-integration 20) ; Elixir↔Rust HTTP boundary, tests/*
  (e2e 10))                 ; full-stack via verisim-api container

 (architecture-decisions
  ;; ADR-style records — each links to a fuller decision doc under
  ;; docs/decisions/.
  (rust-spark-stance
   :location "docs/decisions/rust-spark-stance.adoc"
   :summary "Rust for core; rejected Go/C/C++/Java alternatives based on memory safety, tooling, and ecosystem.")
  (kraft-consensus
   :location "docs/decisions/kraft-comparison.adoc"
   :summary "KRaft (Kafka Raft) over Raft or Paxos for the federation registry; analysis of failure modes, snapshot strategy, leader election.")
  (proven-coherence
   :location "docs/decisions/proven-coherence.md"
   :summary "Notes on integrating the proven library for certificate-based proof exchange.")
  (sha-pinning
   :rationale "Mutable GitHub Actions tags (@v6, @stable) are a supply-chain attack vector. All third-party actions pinned to full SHAs with version comments.")
  (rsr-template-alignment
   :rationale "Top-level documents conform to hyperpolymath/rsr-template-repo so estate-wide tooling (governance, scorecard, hypatia) can reason about the repo."))

 (test-bench-standards-source
  ;; Where the testing & benchmarking decisions are codified.
  :primary "TESTING.md"
  :secondary
  ("rust-core/verisim-planner/tests/snapshot_tests.rs"  ; insta example
   ".cargo/mutants.toml"                                ; cargo-mutants config
   "rust-core/verisim-spatial/tests/property_tests.rs"  ; proptest example
   "elixir-orchestration/test/verisim/property/"        ; stream_data examples
   "elixir-orchestration/bench/"                        ; benchee examples
   "benches/modality_benchmarks.rs"))                   ; criterion example

 (cicd-shape
  (gitlab "primary; .gitlab-ci.yml is canonical")
  (github-actions
   ("rust-ci.yml: fmt, clippy --all-targets -D warnings, test, doc, audit, deny, bench-compile, fuzz-compile (matrix), coverage, mutants (opt-in)"
    "elixir-ci.yml: format, compile --warnings-as-errors, test, hex audit, coverage (informational), bench-compile"
    "governance.yml: estate-wide reusable from hyperpolymath/standards"
    "codeql.yml, secret-scanner.yml, scorecard*.yml, spark-theatre-gate.yml — security gates"
    "cflite_batch.yml, cflite_pr.yml — ClusterFuzzLite"
    "hypatia-scan.yml — semantic CI analysis"
    "instant-sync.yml, mirror.yml — repo mirror sync"
    "jekyll-gh-pages.yml — GitHub Pages")))

 (governance
  (license "MPL-2.0")
  (copyright "Jonathan D.A. Jewell (hyperpolymath)")
  (maintainers "MAINTAINERS.adoc")
  (code-of-conduct "CODE_OF_CONDUCT.md")
  (security-policy "SECURITY.md")
  (machine-readable-bots ".machine_readable/bot_directives/"))

 (dependencies-strategy
  (rust
   :workspace-deps "Cargo.toml [workspace.dependencies]"
   :version-pinning "patch ranges via ~ for stability, exact pins for security CVEs"
   :supply-chain
   ("deny.toml: license allowlist, advisory ignore list, wildcard policy"
    "Dependabot: daily, grouped by ecosystem"
    "cargo-audit: every PR"
    "cargo-deny: every PR (advisories + bans + licenses + sources)"))
  (elixir
   :version-pinning "patch ranges via ~> for compat, >= pins for CVEs"
   :supply-chain
   ("mix hex.audit: every PR"
    "mix deps.unlock --check-unused: every PR"))))
