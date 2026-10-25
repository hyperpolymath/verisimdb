#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
# Read/delete a 0.26.1 index with the current document-store implementation.
# Run on a committed checkout. Old dependencies live only in the temporary
# copy, so the production lockfile cannot accidentally retain vulnerable lru.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -r -- "$scratch"' EXIT
git -C "$root" archive HEAD | tar -x -C "$scratch"
sed -i 's/tantivy = { version = "0.27"/tantivy = { version = "=0.26.1"/' "$scratch/Cargo.toml"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$root/target}"
cargo update --manifest-path "$scratch/Cargo.toml" -p tantivy --precise 0.26.1
cargo run --manifest-path "$scratch/Cargo.toml" -p verisim-document --example index_upgrade_probe --locked -- write "$scratch/index"
if [[ "${BASELINE_CONTROL:-0}" == 1 ]]; then
  # Same assertion on the old release distinguishes an existing identity bug
  # from an upgrade regression. A failure deliberately propagates to the caller.
  cp -a "$scratch/index" "$scratch/control-index"
  cargo run --manifest-path "$scratch/Cargo.toml" -p verisim-document --example index_upgrade_probe --locked -- read "$scratch/control-index"
fi
cargo run --manifest-path "$root/Cargo.toml" -p verisim-document --example index_upgrade_probe --locked -- read "$scratch/index"
echo 'PASS: Tantivy 0.26.1 stored id/title/body and search are readable and deletable after upgrade'
