;; SPDX-License-Identifier: MPL-2.0
;; Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
;;
;; STATE.scm — current project state and progress.
;;
;; Machine-readable counterpart to KNOWN-ISSUES.adoc, ROADMAP.md, and
;; CHANGELOG.adoc.  Updated whenever a substantive change ships.

(state
 (project "verisimdb")
 (canonical-name "VeriSimDB")
 (subtitle "Veridical Simulacrum Database")
 (snapshot-date "2026-05-26")

 (release
  (latest "0.1.0-alpha")
  (latest-date "2026-02-04")
  (next "0.2.0-alpha")
  (release-notes-dir "docs/releases/"))

 (audit-trail
  ;; All 25 catalogued issues resolved; KNOWN-ISSUES.adoc preserved
  ;; as audit history.
  (open-issues 0)
  (resolved-issues 25)
  (sources
   ("KNOWN-ISSUES.adoc" "AUDIT.adoc" "CHANGELOG.adoc")))

 (testing
  (rust
   (unit-tests 567)
   (integration-tests 25)
   (property-tests 14)
   (snapshot-tests 4)
   (doctest-discipline "partial — Rust public APIs have inline examples in most crates")
   (fuzz-targets 2)
   (benchmarks-modalities 8) ; all of: document, vector, graph, octad, drift,
                              ; cross-modal, tensor, semantic, temporal,
                              ; spatial, provenance — actually 11 groups
                              ; total counting drift + cross-modal as
                              ; separate from per-modality
   (gates
    (clippy "all-targets -D warnings")
    (fmt "cargo fmt --all -- --check")
    (doc "cargo doc --no-deps, RUSTDOCFLAGS=-D warnings")
    (audit "cargo audit")
    (deny "cargo deny check advisories bans licenses sources")
    (coverage "cargo llvm-cov informational, target ≥60% line")
    (mutation-testing "cargo-mutants opt-in via workflow_dispatch")))
  (elixir
   (test-files 46)
   (property-test-files 2)
   (benchmark-scripts 5)
   (modules-with-tests-of-9 9)
   (gates
    (format "mix format --check-formatted")
    (compile "mix compile --warnings-as-errors")
    (test "mix test")
    (audit "mix hex.audit + mix deps.unlock --check-unused")
    (coverage "mix coveralls.json, target ≥60% line"))))

 (test-coverage-modules
  ;; Status of the 9 modules flagged in the test-gap audit.
  (drift-monitor :covered :pr-35)
  (entity-server :covered :pr-35)
  (query-router :covered :pr-35)
  (schema-registry :covered :pr-37)
  (kraft-supervisor :covered :pr-37)
  (vql-bridge :covered :pr-37)
  (vql-executor :covered :pr-37)
  (telemetry-collector :covered :existing-via-TelemetryTest)
  (telemetry-reporter :covered :existing-via-TelemetryTest))

 (security
  (vulnerabilities
   (rust-cargo-audit
    (real 0)
    (advisories 6) ; bincode, core2, paste, rustls-pemfile (unmaintained);
                   ; lru (unsound) — all transitive in burn ML stack
    (deny-config ".cargo/.. + deny.toml ignore list, documented"))
   (elixir-hex-audit
    (real 0)
    (cve-pins-in-mix-exs
     ("bandit >= 1.11.1"  ; GHSA-rf5q-vwxw-gmrf
      "plug >= 1.19.2"     ; GHSA-468c-vq7p-gh64
      "postgrex >= 0.22.2"))) ; GHSA-r73h-97w8-m54h
   (dependabot-alerts 3)) ; default branch as of last push
  (supply-chain
   (github-actions-pin-strategy "full-SHA + version comment")
   (workflows-pinned ("rust-ci.yml" "elixir-ci.yml" "secret-scanner.yml" "cflite_pr.yml"))))

 (modalities
  ;; Each octad modality and its current implementation status.
  (graph (status :implemented) (default-backend :simple) (optional-backend :oxigraph))
  (vector (status :implemented) (algorithm :hnsw))
  (tensor (status :implemented) (backend :ndarray-burn))
  (semantic (status :implemented) (proof-types 11))
  (document (status :implemented) (backend :tantivy))
  (temporal (status :implemented))
  (provenance (status :implemented) (integrity :sha-256-hash-chain))
  (spatial (status :implemented) (index :r-tree)))

 (taxonomy
  ;; Repo layout per rsr-template-repo convention.
  (top-level
   ("README.adoc" "LICENSE" "CHANGELOG.adoc" "CODE_OF_CONDUCT.md"
    "CONTRIBUTING.md" "MAINTAINERS.adoc" "SECURITY.md" "KNOWN-ISSUES.adoc"
    "TESTING.md" "ROADMAP.md" "AUDIT.adoc" "0-AI-MANIFEST.a2ml"
    "justfile" "sync-wiki.sh"))
  (docs-tree
   ("architecture" "decisions" "deployment" "status" "releases"
    "papers" "visualizations" "business" "design"))
  (docs-index "docs/INDEX.md"))

 (build
  (rust-toolchain "stable, MSRV undeclared — uses 2021 edition")
  (rust-workspace-crates 17)
  (elixir-version "1.17")
  (otp-version "27"))

 (open-prs ())                              ; check via mcp__github tools
 (open-issues ())                           ; same

 (next-actions
  ;; In priority order from the testing+benchmarking research brief.
  (tier-1-adopted
   (benchee :done)
   (excoveralls :done)
   (cargo-llvm-cov :done)
   (proptest :done)
   (stream-data :done))
  (tier-2-adopted
   (insta :done)
   (cargo-mutants :configured-opt-in))
  (tier-2-deferred
   (mneme "Elixir snapshot — interactive accept/reject doesn't fit batch CI")
   (differential-testing "redb vs Oxigraph result-set equivalence")
   (doctest-discipline "needs per-public-fn pass"))
  (tier-3-deferred
   (loom-shuttle "concurrency model-checker, nightly only")
   (codspeed-bencher "bench-as-PR-gate, needs external account")
   (afl-plus-plus "structure-aware fuzzing"))))
