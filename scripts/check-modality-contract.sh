#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Bind docs/modality-profile.adoc annotations to the schema and Rust fields.
# Usage: scripts/check-modality-contract.sh [root]
# Exit: 0 agreement; 1 drift; 2 missing, malformed or unreadable input.
# Requires Bash and jq. This compares the existing contract; it does not
# validate payloads or encode the known schema/API divergences as expected.
set -euo pipefail

fail() {
    echo "ERROR: $*" >&2
    exit 2
}

command -v jq >/dev/null 2>&1 || fail "jq missing — cannot check the modality contract"
ROOT=${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
[[ -d "$ROOT" ]] || fail "scan root does not exist: $ROOT"
DOC=docs/modality-profile.adoc
MODALITY_ENUM=connectors/shared/json-schema/modality.json
INPUT_SCHEMA=connectors/shared/json-schema/octad-input.json
CORE_LIB=rust-core/verisim-octad/src/lib.rs
for rel in "$DOC" "$MODALITY_ENUM" "$INPUT_SCHEMA" "$CORE_LIB"; do
    [[ -f "$ROOT/$rel" ]] || fail "missing required file: $rel"
done

if ! result=$(jq -n \
    --arg doc_path "$DOC" --arg enum_path "$MODALITY_ENUM" \
    --arg schema_path "$INPUT_SCHEMA" --arg core_path "$CORE_LIB" \
    --rawfile doc "$ROOT/$DOC" --slurpfile enums "$ROOT/$MODALITY_ENUM" \
    --slurpfile schemas "$ROOT/$INPUT_SCHEMA" --rawfile source "$ROOT/$CORE_LIB" '
    def annotations:
        [$doc | split("\n")[] |
         capture("^\\s*//\\s*modality-contract:\\s*(?<key>[a-z-]+)\\s*=\\s*(?<value>.+?)\\s*$")?]
        | group_by(.key)
        | if any(.[]; length > 1) then
              error($doc_path + " declares a modality-contract annotation more than once")
          else map({key: .[0].key, value: (.[0].value | split(",") |
                   map(gsub("^\\s+|\\s+$"; "") | select(length > 0)))}) | from_entries
          end
        | if has("octad-slots") and has("payload-fields") then .
          else error($doc_path + " is missing a required modality-contract annotation") end;
    def struct_fields($name):
        ([$source | capture("pub struct " + $name + "\\b[^\\{]*\\{(?<body>.*?)\\n\\}"; "m")]
         | if length == 0 then error("could not find pub struct " + $name + " in " + $core_path)
           else .[0].body end)
        | [split("\n")[] |
           capture("^\\s*pub\\s+(?<field>[a-z_][a-z0-9_]*)\\s*:")? | .field];
    def compare($label; $left; $right):
        ($left | unique) as $l | ($right | unique) as $r |
        [$l - $r | .[] | $label + ": " + tojson + " is on the left side only"] +
        [$r - $l | .[] | $label + ": " + tojson + " is on the right side only"];

    annotations as $annotations |
    (if ($enums | length) == 1 and ($enums[0] | type) == "object" and
        ($enums[0].enum | type) == "array" and ($enums[0].enum | length) > 0
     then $enums[0].enum else error($enum_path + " has no non-empty enum") end) as $enum |
    (if ($schemas | length) == 1 and ($schemas[0] | type) == "object" and
        ($schemas[0].properties | type) == "object" and ($schemas[0].properties | length) > 0
     then $schemas[0] else error($schema_path + " has no properties") end) as $schema |
    struct_fields("ModalityStatus") as $status_fields |
    struct_fields("OctadInput") as $input_fields |
    ($annotations["octad-slots"] | unique) as $slots |
    ($annotations["payload-fields"] | unique) as $payload |
    ($slots - $payload) as $not_settable |
    {
        slot_count: ($annotations["octad-slots"] | length),
        payload_count: ($annotations["payload-fields"] | length),
        mismatches: (
            compare($doc_path + " octad-slots vs " + $enum_path + " enum"; $slots; $enum) +
            compare($doc_path + " octad-slots vs ModalityStatus fields"; $slots; $status_fields) +
            compare($doc_path + " payload-fields vs " + $schema_path + " properties";
                    $payload; ($schema.properties | keys)) +
            compare($doc_path + " payload-fields vs OctadInput fields"; $payload; $input_fields) +
            (if $schema.additionalProperties == false then [] else
                [$schema_path + ": additionalProperties must be false — the document states that no ninth modality is expressible in the schema"] end) +
            (if $not_settable == ["temporal"] then [] else
                [$doc_path + ": slots not settable via OctadInput are " + ($not_settable | tojson) +
                 "; the document states this set is exactly {temporal} — update §5 and this gate together if the contract really changed"] end)
        )
    }
'); then
    fail "could not read the modality contract inputs"
fi

if [[ $(jq '.mismatches | length' <<< "$result") != 0 ]]; then
    echo "FAIL modality-contract: the document and the implementation disagree." >&2
    jq -r '.mismatches[] | "       - " + .' <<< "$result" >&2
    echo "       The document is normative for words only. Fix $DOC, or, if the contract itself changed, that is an owner decision that lands with a versioned schema and tests — see §10 of the document." >&2
    exit 1
fi

jq -r '"PASS modality-contract: \(.slot_count) octad slots and \(.payload_count) payload fields agree across doc, modality.json, octad-input.json and the Rust core"' <<< "$result"
