#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# modality-contract-gate.sh — positive control for check-modality-contract.py.
#
# Same shape as tests/doc-links-gate.sh: run the real checker first, then plant
# known-bad fixtures in a scratch tree and assert the checker (a) fails and
# (b) fails for the RIGHT reason.
#
# WHY: docs/modality-profile.adoc is a prose document that asserts eight slots,
# seven settable payload fields and a closed schema. A checker that passes on a
# clean tree is indistinguishable from one that checks nothing at all — so this
# test mutates the *evidence* (the modality enum, the Rust struct, the schema) and
# asserts the document is reported as no longer matching it.
#
# Fixtures are minimal copies, not the whole repository: the checker only needs
# four inputs, and copying a Rust crate into /tmp to test a Python script would be
# slow without being any more convincing.

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CHECKER="$REPO_ROOT/scripts/check-modality-contract.py"
FIXTURE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/verisimdb-modality-contract.XXXXXX")
trap 'rm -rf -- "$FIXTURE_DIR"' EXIT

if [[ ! -x "$CHECKER" ]]; then
    echo "ERROR: checker is not executable: $CHECKER" >&2
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 missing on runner — cannot check the modality contract" >&2
    exit 2
fi

plant() {
    # plant <dir> — copy just the four artefacts the checker reads.
    local dir=$1
    mkdir -p "$dir/docs" "$dir/connectors/shared/json-schema" "$dir/rust-core/verisim-octad/src"
    cp "$REPO_ROOT/docs/modality-profile.adoc"                        "$dir/docs/"
    cp "$REPO_ROOT/connectors/shared/json-schema/modality.json"       "$dir/connectors/shared/json-schema/"
    cp "$REPO_ROOT/connectors/shared/json-schema/octad-input.json"    "$dir/connectors/shared/json-schema/"
    cp "$REPO_ROOT/rust-core/verisim-octad/src/lib.rs"                "$dir/rust-core/verisim-octad/src/"
}

expect_failure() {
    # expect_failure <label> <dir> <needle>
    local label=$1 dir=$2 needle=$3
    local output result
    set +e
    output=$("$CHECKER" "$dir" 2>&1)
    result=$?
    set -e
    if (( result == 0 )); then
        echo "ERROR: checker accepted $label" >&2
        echo "       A checker that passes a mutated tree is not checking anything." >&2
        exit 1
    fi
    if [[ "$output" != *"$needle"* ]]; then
        echo "ERROR: checker rejected $label but did not name the cause" >&2
        echo "       expected to see: $needle" >&2
        echo "--- checker output ---" >&2
        echo "$output" >&2
        exit 1
    fi
}

echo "[1/6] checking the working tree..."
"$CHECKER" "$REPO_ROOT"

echo "[2/6] planting a clean fixture (must pass)..."
DIR_OK="$FIXTURE_DIR/ok"
plant "$DIR_OK"
if ! "$CHECKER" "$DIR_OK" >/dev/null; then
    echo "ERROR: checker rejects a faithful copy of the current tree" >&2
    "$CHECKER" "$DIR_OK" >&2 || true
    exit 1
fi

echo "[3/6] adding a ninth modality to the enum (doc must be reported stale)..."
DIR_ENUM="$FIXTURE_DIR/enum"
plant "$DIR_ENUM"
python3 - "$DIR_ENUM/connectors/shared/json-schema/modality.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as fh:
    data = json.load(fh)
data["enum"].append("topological")
with open(path, "w") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
PY
expect_failure "an enum with a ninth modality" "$DIR_ENUM" "topological"

echo "[4/6] renaming a ModalityStatus field (doc must be reported stale)..."
DIR_RUST="$FIXTURE_DIR/rust"
plant "$DIR_RUST"
python3 - "$DIR_RUST/rust-core/verisim-octad/src/lib.rs" <<'PY'
import sys
path = sys.argv[1]
with open(path) as fh:
    source = fh.read()
# Rename only inside ModalityStatus, leaving every other `spatial` reference.
start = source.index("pub struct ModalityStatus")
end = source.index("}", source.index("pub spatial: bool", start))
block = source[start:end]
source = source[:start] + block.replace("pub spatial: bool", "pub geospatial: bool") + source[end:]
with open(path, "w") as fh:
    fh.write(source)
PY
expect_failure "a renamed ModalityStatus field" "$DIR_RUST" "geospatial"

echo "[5/6] opening the schema (doc promises a closed object)..."
DIR_SCHEMA="$FIXTURE_DIR/schema"
plant "$DIR_SCHEMA"
python3 - "$DIR_SCHEMA/connectors/shared/json-schema/octad-input.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as fh:
    data = json.load(fh)
data["additionalProperties"] = True
with open(path, "w") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
PY
expect_failure "an open schema" "$DIR_SCHEMA" "additionalProperties"

echo "[6/6] editing the doc's own slot list (doc contradicts the code)..."
DIR_DOC="$FIXTURE_DIR/doc"
plant "$DIR_DOC"
python3 - "$DIR_DOC/docs/modality-profile.adoc" <<'PY'
import sys
path = sys.argv[1]
with open(path) as fh:
    text = fh.read()
needle = "octad-slots = graph, vector, tensor, semantic, document, temporal, provenance, spatial"
assert needle in text, "fixture no longer matches the annotation format"
text = text.replace(needle, needle + ", acoustic")
with open(path, "w") as fh:
    fh.write(text)
PY
expect_failure "a doc slot list the code does not have" "$DIR_DOC" "acoustic"

echo "PASS modality-contract-gate: checker passes the real tree and rejects all four planted drift directions"
