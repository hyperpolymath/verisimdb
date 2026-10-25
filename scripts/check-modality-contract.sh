#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# Bind documentation annotations to the fixed Octad schema and Rust fields.
# Preserves the original Python checker's four comparisons, closed-schema
# check and implicit-Temporal check. Bash, awk and jq only; no policy exemption.
# Usage: bash scripts/check-modality-contract.sh [root]
set -euo pipefail
root=${1:-$(cd "$(dirname "$0")/.." && pwd)}
doc=docs/modality-profile.adoc
enum=connectors/shared/json-schema/modality.json
schema=connectors/shared/json-schema/octad-input.json
core=rust-core/verisim-octad/src/lib.rs
fail() { echo "ERROR: $*" >&2; exit 2; }
for tool in awk jq; do command -v "$tool" >/dev/null || fail "$tool missing"; done
for path in "$doc" "$enum" "$schema" "$core"; do
  [[ -f "$root/$path" ]] || fail "missing required file: $path"
done
annotation() {
  local value
  value=$(awk -v key="$1" '
    $0 ~ "^[[:space:]]*//[[:space:]]*modality-contract:[[:space:]]*" key "[[:space:]]*=" {
      count++; sub(/^[^=]*=[[:space:]]*/, ""); print
    }
    END { if (count != 1) exit 2 }
  ' "$root/$doc") || fail "$doc: missing or duplicate modality-contract: $1"
  jq -cn --arg value "$value" '
    def trim: gsub("^\\s+|\\s+$"; "");
    $value | split(",")
    | if length != (map(trim) | unique | length)
      then error("duplicate annotation entry")
      else map(trim) | map(select(length > 0)) | unique
      end'
}
fields() {
  local value
  value=$(awk -v name="$1" '
    $0 ~ "^pub struct " name "[[:space:]]*\\{" { active=1; found++; next }
    active && /^}/ { active=0; closed++; next }
    active && /^[[:space:]]*pub[[:space:]]+[a-z_][a-z0-9_]*[[:space:]]*:/ {
      sub(/^[[:space:]]*pub[[:space:]]+/, ""); sub(/[[:space:]]*:.*/, ""); print
    }
    END { if (found != 1 || closed != 1) exit 2 }
  ' "$root/$core") || fail "could not find complete pub struct $1 in $core"
  jq -cn --arg value "$value" '$value | split("\n") | map(select(length > 0)) | unique'
}
slots=$(annotation octad-slots)
payload=$(annotation payload-fields)
status=$(fields ModalityStatus)
input=$(fields OctadInput)
enum_fields=$(jq -ce '.enum | select(type == "array" and length > 0) | select(all(.[]; type == "string")) | unique' "$root/$enum") || fail "$enum: invalid JSON or enum"
schema_fields=$(jq -ce '.properties | select(type == "object" and length > 0) | keys' "$root/$schema") || fail "$schema: invalid JSON or properties"
closed=$(jq -c '.additionalProperties == false' "$root/$schema") || fail "$schema: invalid JSON"
errors=$(jq -cn --argjson slots "$slots" --argjson payload "$payload" \
  --argjson status "$status" --argjson input "$input" --argjson enum "$enum_fields" \
  --argjson props "$schema_fields" --argjson closed "$closed" '
  def compare($label; $left; $right):
    (($left - $right)[] | "\($label): \(.) is on the left side only"),
    (($right - $left)[] | "\($label): \(.) is on the right side only");
  [compare("doc octad-slots vs modality enum"; $slots; $enum),
   compare("doc octad-slots vs ModalityStatus"; $slots; $status),
   compare("doc payload-fields vs schema properties"; $payload; $props),
   compare("doc payload-fields vs OctadInput"; $payload; $input),
   (if $closed then empty else "additionalProperties must be false" end),
   (if ($slots - $payload) == ["temporal"] then empty
    else "slots not settable via OctadInput must be exactly temporal" end)]')
if [[ "$errors" != '[]' ]]; then
  echo 'FAIL modality-contract: the document and implementation disagree.' >&2
  jq -r '.[] | "  - " + .' <<< "$errors" >&2
  exit 1
fi
echo "PASS modality-contract: $(jq length <<< "$slots") slots and $(jq length <<< "$payload") payload fields agree; Temporal is implicit"
