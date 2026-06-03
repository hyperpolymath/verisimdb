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

# ── Toolchain floor ──────────────────────────────────────────────────────
# The OSS-Fuzz base-builder-rust image pins an older nightly (rustc 1.91 at
# time of writing), but part of the dependency graph — burn / cubecl-zspace,
# pulled transitively via verisim-tensor (rust-core/fuzz -> verisim-api) —
# declares rust-version = 1.92. cargo-fuzz rebuilds the standard library with
# -Zbuild-std, so all we need is a new-enough nightly with rust-src present.
# Install one and force it for the whole script via RUSTUP_TOOLCHAIN. This is
# contained to the fuzz job: it never touches the main workspace toolchain or
# any other CI job.
rustup toolchain install nightly --profile minimal \
    --component rust-src --component llvm-tools-preview
export RUSTUP_TOOLCHAIN=nightly

# cargo-fuzz drives libfuzzer; install it if missing.
if ! command -v cargo-fuzz &>/dev/null; then
    cargo install cargo-fuzz --locked
fi

# Build one named fuzz target in a given crate directory and copy the binary
# to $OUT. We build the target *by name* and then locate the produced binary
# wherever cargo-fuzz placed it (instead of a brittle glob), failing loudly if
# nothing was produced. Combined with the two fuzz crates carrying distinct
# package names, this is robust against the shared-target-dir collision that
# previously turned the second build into a silent 0.01s no-op.
build_target() {
    local crate_dir="$1" target="$2"
    echo "── building fuzz target '${target}' in ${crate_dir} ──"
    (
        cd "${crate_dir}"
        cargo fuzz build --release --sanitizer="${SANITIZER:-address}" "${target}"
        local bin
        bin="$(find . -type f -name "${target}" -path '*/release/*' -print -quit)"
        if [[ -z "${bin}" ]]; then
            echo "ERROR: no '${target}' binary produced under ${crate_dir}" >&2
            exit 1
        fi
        cp "${bin}" "${OUT}/${target}"
        echo "── copied ${bin} -> ${OUT}/${target} ──"
    )
}

build_target "${SRC}/verisimdb/fuzz"           fuzz_octad_id
build_target "${SRC}/verisimdb/rust-core/fuzz" fuzz_vql_parser

# Optional seed corpora — empty for now, will populate as we discover
# interesting inputs.  Comment in once corpora exist:
# cp -r "${SRC}/verisimdb/fuzz/corpus/fuzz_octad_id" "${OUT}/fuzz_octad_id_seed_corpus" 2>/dev/null || true
# cp -r "${SRC}/verisimdb/rust-core/fuzz/corpus/fuzz_vql_parser" "${OUT}/fuzz_vql_parser_seed_corpus" 2>/dev/null || true
