#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# modality-contract-gate.sh — positive control for check-modality-contract.sh.
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
# four inputs, and copying a Rust crate into /tmp to test a static checker would be
# slow without being any more convincing.

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CHECKER="$REPO_ROOT/scripts/check-modality-contract.sh"
FIXTURE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/verisimdb-modality-contract.XXXXXX")
trap 'rm -rf -- "$FIXTURE_DIR"' EXIT

if [[ ! -x "$CHECKER" ]]; then
    echo "ERROR: checker is not executable: $CHECKER" >&2
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq missing on runner — cannot check the modality contract" >&2
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
    # expect_failure <label> <dir> <needle> [exit-status, default 1 for drift]
    local label=$1 dir=$2 needle=$3 expected_status=${4:-1}
    local output result
    set +e
    output=$("$CHECKER" "$dir" 2>&1)
    result=$?
    set -e
    if (( result != expected_status )); then
        echo "ERROR: checker returned $result for $label; expected $expected_status" >&2
        echo "$output" >&2
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

echo "[1/13] checking the working tree..."
"$CHECKER" "$REPO_ROOT"

echo "[2/13] planting a clean fixture (must pass)..."
DIR_OK="$FIXTURE_DIR/ok"
plant "$DIR_OK"
if ! "$CHECKER" "$DIR_OK" >/dev/null; then
    echo "ERROR: checker rejects a faithful copy of the current tree" >&2
    "$CHECKER" "$DIR_OK" >&2 || true
    exit 1
fi

echo "[3/13] adding a ninth modality to the enum (doc must be reported stale)..."
DIR_ENUM="$FIXTURE_DIR/enum"
plant "$DIR_ENUM"
jq '.enum += ["topological"]' "$DIR_ENUM/connectors/shared/json-schema/modality.json" > "$FIXTURE_DIR/enum.json"
mv "$FIXTURE_DIR/enum.json" "$DIR_ENUM/connectors/shared/json-schema/modality.json"
expect_failure "an enum with a ninth modality" "$DIR_ENUM" "topological"

echo "[4/13] renaming a ModalityStatus field (doc must be reported stale)..."
DIR_RUST="$FIXTURE_DIR/rust"
plant "$DIR_RUST"
# Rename only inside ModalityStatus, leaving every other spatial reference.
sed '/pub struct ModalityStatus/,/^}/s/pub spatial: bool/pub geospatial: bool/' \
    "$DIR_RUST/rust-core/verisim-octad/src/lib.rs" > "$FIXTURE_DIR/lib.rs"
mv "$FIXTURE_DIR/lib.rs" "$DIR_RUST/rust-core/verisim-octad/src/lib.rs"
expect_failure "a renamed ModalityStatus field" "$DIR_RUST" "geospatial"

echo "[5/13] opening the schema (doc promises a closed object)..."
DIR_SCHEMA="$FIXTURE_DIR/schema"
plant "$DIR_SCHEMA"
jq '.additionalProperties = true' "$DIR_SCHEMA/connectors/shared/json-schema/octad-input.json" > "$FIXTURE_DIR/input.json"
mv "$FIXTURE_DIR/input.json" "$DIR_SCHEMA/connectors/shared/json-schema/octad-input.json"
expect_failure "an open schema" "$DIR_SCHEMA" "additionalProperties"

echo "[6/13] editing the doc's own slot list (doc contradicts the code)..."
DIR_DOC="$FIXTURE_DIR/doc"
plant "$DIR_DOC"
sed '/modality-contract: octad-slots = /s/$/, acoustic/' \
    "$DIR_DOC/docs/modality-profile.adoc" > "$FIXTURE_DIR/profile.adoc"
mv "$FIXTURE_DIR/profile.adoc" "$DIR_DOC/docs/modality-profile.adoc"
expect_failure "a doc slot list the code does not have" "$DIR_DOC" "acoustic"

echo "[7/13] adding a schema payload field..."
DIR_PAYLOAD="$FIXTURE_DIR/payload"
plant "$DIR_PAYLOAD"
jq '.properties.acoustic = {}' "$DIR_PAYLOAD/connectors/shared/json-schema/octad-input.json" > "$FIXTURE_DIR/payload.json"
mv "$FIXTURE_DIR/payload.json" "$DIR_PAYLOAD/connectors/shared/json-schema/octad-input.json"
expect_failure "an extra schema payload field" "$DIR_PAYLOAD" "acoustic"

echo "[8/13] renaming an OctadInput field..."
DIR_INPUT="$FIXTURE_DIR/input"
plant "$DIR_INPUT"
sed '/pub struct OctadInput/,/^}/s/pub spatial:/pub geospatial:/' \
    "$DIR_INPUT/rust-core/verisim-octad/src/lib.rs" > "$FIXTURE_DIR/input.rs"
mv "$FIXTURE_DIR/input.rs" "$DIR_INPUT/rust-core/verisim-octad/src/lib.rs"
expect_failure "a renamed OctadInput field" "$DIR_INPUT" "geospatial"

echo "[9/13] duplicating a document annotation..."
DIR_DUPLICATE="$FIXTURE_DIR/duplicate"
plant "$DIR_DUPLICATE"
grep 'modality-contract: octad-slots = ' "$REPO_ROOT/docs/modality-profile.adoc" >> "$DIR_DUPLICATE/docs/modality-profile.adoc"
expect_failure "a duplicate annotation" "$DIR_DUPLICATE" "more than once" 2

echo "[10/13] removing a required document annotation..."
DIR_ANNOTATION="$FIXTURE_DIR/annotation"
plant "$DIR_ANNOTATION"
sed '/modality-contract: payload-fields = /d' "$DIR_ANNOTATION/docs/modality-profile.adoc" > "$FIXTURE_DIR/annotation.adoc"
mv "$FIXTURE_DIR/annotation.adoc" "$DIR_ANNOTATION/docs/modality-profile.adoc"
expect_failure "a missing annotation" "$DIR_ANNOTATION" "missing" 2

echo "[11/13] corrupting a JSON input..."
DIR_JSON="$FIXTURE_DIR/json"
plant "$DIR_JSON"
printf '{invalid\n' > "$DIR_JSON/connectors/shared/json-schema/modality.json"
expect_failure "malformed JSON" "$DIR_JSON" "modality.json" 2

echo "[12/13] removing a Rust struct declaration..."
DIR_STRUCT="$FIXTURE_DIR/struct"
plant "$DIR_STRUCT"
sed 's/pub struct ModalityStatus/pub struct RenamedStatus/' \
    "$DIR_STRUCT/rust-core/verisim-octad/src/lib.rs" > "$FIXTURE_DIR/struct.rs"
mv "$FIXTURE_DIR/struct.rs" "$DIR_STRUCT/rust-core/verisim-octad/src/lib.rs"
expect_failure "a missing Rust struct" "$DIR_STRUCT" "pub struct ModalityStatus" 2

echo "[13/13] removing a required file..."
DIR_MISSING="$FIXTURE_DIR/missing"
plant "$DIR_MISSING"
rm "$DIR_MISSING/connectors/shared/json-schema/octad-input.json"
expect_failure "a missing input file" "$DIR_MISSING" "missing required file" 2

echo "PASS modality-contract-gate: checker passes the real tree and rejects all planted drift directions and invalid inputs"
