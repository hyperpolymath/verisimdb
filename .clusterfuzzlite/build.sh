#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# ClusterFuzzLite build script for VeriSimDB
#
# Builds both fuzz harnesses with libfuzzer instrumentation and copies the
# resulting binaries to $OUT (where ClusterFuzzLite expects them).
#
# Required env vars (set by ClusterFuzzLite runner):
#   $OUT             — output directory for built fuzzer binaries
#   $SRC             — source root (typically /src/verisimdb)
#   $SANITIZER       — address | undefined | memory  (we honour via RUSTFLAGS)

set -euo pipefail

# cargo-fuzz drives libfuzzer; install it if missing.
if ! command -v cargo-fuzz &>/dev/null; then
    cargo install cargo-fuzz --locked
fi

# ── fuzz_octad_id — top-level fuzz crate ─────────────────────────────────
cd "${SRC}/verisimdb/fuzz"
cargo fuzz build --release --sanitizer="${SANITIZER:-address}"
cp target/*/release/fuzz_octad_id "${OUT}/"

# ── fuzz_vql_parser — rust-core fuzz crate ───────────────────────────────
cd "${SRC}/verisimdb/rust-core/fuzz"
cargo fuzz build --release --sanitizer="${SANITIZER:-address}"
cp target/*/release/fuzz_vql_parser "${OUT}/"

# Optional seed corpora — empty for now, will populate as we discover
# interesting inputs.  Comment in once corpora exist:
# cp -r "${SRC}/verisimdb/fuzz/corpus/fuzz_octad_id" "${OUT}/fuzz_octad_id_seed_corpus" 2>/dev/null || true
# cp -r "${SRC}/verisimdb/rust-core/fuzz/corpus/fuzz_vql_parser" "${OUT}/fuzz_vql_parser_seed_corpus" 2>/dev/null || true
