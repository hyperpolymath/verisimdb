#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Positive-control test for the classification registry gate.

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VALIDATOR="$REPO_ROOT/scripts/validate-assail-classifications.sh"
FIXTURE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/verisimdb-assail-gate.XXXXXX")
trap 'rm -rf -- "$FIXTURE_DIR"' EXIT

"$VALIDATOR"

MUTANT="$FIXTURE_DIR/missing-path.a2ml"
cp "$REPO_ROOT/audits/assail-classifications.a2ml" "$MUTANT"
sed -i '0,/elixir-orchestration\/lib\/verisim\/federation\/adapters\/object_storage.ex/s//missing\/positive-control.ex/' "$MUTANT"

set +e
output=$("$VALIDATOR" "$MUTANT" 2>&1)
result=$?
set -e

if (( result == 0 )); then
    echo "ERROR: validator accepted a planted missing classification target" >&2
    exit 1
fi

if [[ "$output" != *"classification target does not exist: missing/positive-control.ex"* ]]; then
    echo "ERROR: validator failed for the wrong reason" >&2
    echo "$output" >&2
    exit 1
fi

echo "positive control passed: planted missing target was rejected"
