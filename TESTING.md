# VeriSimDB Testing & Benchmarking Standards

> Last updated: 2026-05-24. Status: Tier 1 standards adopted; Tier 2/3 documented as next steps.

## Levels of evidence

We treat testing as a pyramid weighted toward unit/property tests in the
Rust core and integration tests at the Elixir↔Rust HTTP boundary.

| Layer | Tooling | Where it lives | Gate |
|---|---|---|---|
| Unit (Rust) | `cargo test` + `#[cfg(test)] mod tests` | `rust-core/*/src/**/*.rs` | rust-ci/test |
| Integration (Rust) | `cargo test --test <name>` | `rust-core/*/tests/*.rs` | rust-ci/test |
| Property (Rust) | `proptest` | `rust-core/*/tests/property_tests.rs` | rust-ci/test |
| Fuzz (Rust) | `cargo-fuzz` + libFuzzer | `fuzz/` and `rust-core/fuzz/` | rust-ci/fuzz-compile + ClusterFuzzLite |
| Bench (Rust) | `criterion` | `benches/modality_benchmarks.rs` | rust-ci/bench-compile |
| Doctest (Rust) | `cargo test --doc` | `///` in any `lib.rs` | rust-ci/test |
| Unit (Elixir) | `ExUnit` | `elixir-orchestration/test/**/*_test.exs` | elixir-ci/build-test |
| Property (Elixir) | `stream_data` via `use ExUnitProperties` | `test/verisim/property/*_props_test.exs` | elixir-ci/build-test |
| Bench (Elixir) | `benchee` | `bench/*_bench.exs`, JSON output | elixir-ci/bench-compile |
| Coverage (Rust) | `cargo-llvm-cov` → Codecov | CI ephemeral | rust-ci/coverage (≥60% gate) |
| Coverage (Elixir) | `excoveralls` → Codecov | CI ephemeral | elixir-ci/coverage (≥60% gate) |
| Lint | `clippy --all-targets -D warnings`, `mix compile --warnings-as-errors`, `mix format --check-formatted`, `cargo fmt --all -- --check` | every commit | rust-ci + elixir-ci |
| Supply-chain | `cargo audit`, `cargo deny`, `mix hex.audit`, Dependabot | every PR | rust-ci/audit + rust-ci/deny + elixir-ci/audit |

The coverage floor is set at **60%** to start, with the intention of
ratcheting upward as the test suite matures. The industry baseline is 80%
line coverage (per Codecov's published guidance); we'll move there once
the bigger gap modules (vcl_executor) have richer coverage.

## Rust standards

### Hard gates (rust-ci.yml)

Every push and PR must pass all of:

```bash
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --no-deps -- -D warnings
cargo test --workspace --no-fail-fast
cargo doc --workspace --no-deps        # with RUSTDOCFLAGS="-D warnings"
cargo bench --no-run                    # compile-only
cargo audit
cargo deny check                        # advisories, bans, licenses, sources
cargo llvm-cov --workspace --fail-under-lines 60
```

Plus a matrix `cargo check --manifest-path fuzz/Cargo.toml` and
`rust-core/fuzz/Cargo.toml` so fuzz harnesses stay green.

### Property-based testing — `proptest`

Where to use it:
- Pure functions with mathematical invariants (haversine symmetry, hash-chain integrity, set algebra).
- Round-trips: `decode(encode(x)) == x`, `index(x); get(id) == x`.
- Monotonicity & ordering: `nearest(k)` returns ascending distances.

Patterns adopted:
- Custom `Strategy` over canonical input domains (`-90..=90` for latitude, etc.)
- `prop_filter_map` to discard out-of-domain inputs cleanly
- `tokio::runtime::Runtime` per property to keep async tests deterministic

See `rust-core/verisim-spatial/tests/property_tests.rs` (8 properties)
and `rust-core/verisim-provenance/tests/property_tests.rs` (6 properties)
for the established pattern.

### Benchmarks — `criterion`

All 8 modalities (graph, vector, tensor, semantic, document, temporal,
spatial, provenance) have dedicated benchmark groups in
`benches/modality_benchmarks.rs`. Each group covers at least:
- A throughput measurement (insertions or upserts)
- A query latency at a representative dataset size (~1000 records)

`cargo bench --no-run` is the CI gate; full execution is left to
developers running locally or to a periodic `bench` job.

## Elixir standards

### Hard gates (elixir-ci.yml)

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix coveralls.json    # uploaded to Codecov, ≥60% line-coverage floor
mix hex.audit
mix deps.unlock --check-unused
```

Plus a syntax check that every `bench/*.exs` script parses with
`Code.string_to_quoted!/1` so misformed benchmark scripts don't sneak
through.

### Property-based testing — `stream_data` / `ExUnitProperties`

Where to use it:
- Parser invariants: every UTF-8 input yields `{:ok, _} | {:error, _}` (no panics)
- Source-id round-trips through `FROM HEXAD <uuid>` clauses
- Constraint validation symmetries (required: missing iff rejected; range: in-bounds iff accepted)
- Pure-function determinism (validate(x) called twice yields the same result)

Patterns adopted:
- One `*_props_test.exs` file per module under `test/verisim/property/`
- Module-level `@moduledoc` enumerates each invariant tested
- Generators favour `one_of`/`map` over `any/0` so failures shrink to meaningful minima
- `prop_assume!` guards to skip irrelevant inputs without false-failures

Established examples:
- `test/verisim/property/schema_registry_props_test.exs` (7 properties)
- `test/verisim/property/vcl_bridge_props_test.exs` (6 properties)

### Benchmarks — `benchee`

Per-module scripts under `elixir-orchestration/bench/`:
- `drift_monitor_bench.exs` — report/status/sweep round-trip latency
- `query_router_bench.exs` — per-modality dispatch overhead
- `vql_executor_bench.exs` — explain-plan generation, statement dispatch
- `vql_bridge_bench.exs` — built-in parser throughput (every query shape)
- `schema_registry_bench.exs` — register/get/validate/type_hierarchy

Each script writes JSON to `bench/results/<name>.json`. The intended
workflow is to run benchmarks on a stable branch, commit the JSON as a
baseline, and diff successive runs in CI when perf regressions matter
for a given PR. (No mandatory perf gate yet — manual review of the
diff is the current discipline.)

Common config:

```elixir
Benchee.run(jobs,
  warmup: 2,
  time: 5,
  memory_time: 1,
  reduction_time: 1,
  print: [fast_warning: false],
  formatters: [
    Benchee.Formatters.Console,
    {Benchee.Formatters.JSON, file: "bench/results/<module>.json"}
  ]
)
```

## Cross-cutting

### Documentation tests

- Rust: every public function should have at least one `///` example
  that compiles under `cargo test --doc`. Not yet a hard gate; will be
  promoted once `cargo doc` warnings are zero.
- Elixir: add `doctest MyModule` to test files for any module whose
  `@doc`/`@moduledoc` contains `iex>` examples.

### Fuzz corpus

Both `fuzz/fuzz_targets/fuzz_octad_id.rs` and
`rust-core/fuzz/fuzz_targets/fuzz_vql_parser.rs` accept arbitrary UTF-8
input. Seed corpora live under `fuzz/corpus/<target>/` and
`rust-core/fuzz/corpus/<target>/` once we accumulate interesting
inputs. The build script in `.clusterfuzzlite/build.sh` has commented-out
hooks to wire those into ClusterFuzzLite.

### Supply chain

`cargo audit` + `cargo deny check advisories bans licenses sources` on
every PR. `deny.toml` keeps a small ignore list for transitive
unmaintained crates that live inside the `burn` ML stack and can only be
addressed by upstream releases; each entry is documented inline with
the upstream chain.

`mix hex.audit` and `mix deps.unlock --check-unused` on every Elixir PR.

## Adopted Tier 2 standards

### Snapshot testing — `insta` (Rust)

Where to use it:
- Public structured outputs whose shape is part of a contract — explain
  plans, AST dumps, drift report JSON, normaliser plans.

Patterns adopted:
- `rust-core/verisim-planner/tests/snapshot_tests.rs` snapshots the
  full `ExplainOutput` for three representative `LogicalPlan` fixtures
  (single-modality document, two-modality graph+vector, semantic-proof
  trailing). YAML format chosen so diffs read naturally.
- Workflow when a snapshot fails:
  1. `cargo insta review` — inspect the diff interactively
  2. Accept legitimate changes or fix the regression
  3. Commit the updated `tests/snapshots/*.snap` file
- In CI snapshots are read-only (no `INSTA_UPDATE`): any drift fails
  the build.

Snapshots live under `<crate>/tests/snapshots/*.snap` and are
human-readable YAML. Review them with `git log -p` like any other
source file.

### Mutation testing — `cargo-mutants` (Rust, opt-in)

Configuration in `.cargo/mutants.toml`:
- `exclude_globs` skips generated protobuf, bench harnesses, fuzz
  harnesses, `main.rs` binaries, and build scripts (mutating them
  produces uninteresting survivors).
- `timeout_multiplier = 3.0` gives slower spatial/temporal tests room.

Recommended invocations:
- Local development: `cargo mutants -p verisim-drift` to focus on one
  crate.
- PR triage: `cargo mutants --in-diff origin/main` only mutates lines
  changed against main — keeps runtime under ~5 min for typical
  changesets.
- Nightly/weekly: `cargo mutants -p <core invariant crates>` full run
  for a mutation-score baseline.

CI integration: `rust-ci.yml` has a `mutants` job gated on
`workflow_dispatch` and `schedule` events (full runs take >20 min;
not suitable for every PR). Report uploaded as
`mutants-report` artifact.

Mutation score targets:
- Priority crates (drift, normalizer, spatial, provenance, semantic,
  octad): **≥80%** on core invariants
- Best-effort crates (api, repl, graph): no enforced floor

## Next-tier standards (not yet adopted)

These are documented for future work; no current CI gate enforces them.

- **Snapshot testing (Elixir)**: `mneme` for built-in VCL parser output.
  Skipped initially because `mneme`'s interactive accept/reject doesn't
  fit batch CI; we'd need to wire `MNEME_REPLY=accept` workflow.
- **Differential testing**: SQLancer-style queries through redb vs
  Oxigraph backends and naive linear vs HNSW vector search; assert
  result-set equivalence to catch optimiser bugs.
- **Concurrency testing**: `loom` + `shuttle` for `verisim-octad` WAL
  transactions; `concuerror` for Elixir supervision tree.
- **Bench-as-PR-gate**: `codspeed-criterion-compat` or `bencher.dev`
  for noise-resistant perf regression detection.
- **AFL++ alongside libFuzzer**: structure-aware fuzzing of the VCL
  grammar via `arbitrary` derive on AST types, corpus sync across
  cargo-fuzz / AFL++ / honggfuzz.
