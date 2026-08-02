#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# demo-admissibility.sh — VCLTGate admissibility check, end to end.
#
# Shows the gate protocol: statements that parse cleanly are admitted;
# structurally malformed statements are rejected before touching the store.
# The gate is a pure function: no network, no filesystem side effects.
#
# Usage:
#   scripts/demo-admissibility.sh                    # finds vclt-gate in PATH or sibling repo
#   VCLT_GATE=/path/to/vclt-gate scripts/demo-admissibility.sh
#
# The vclt-gate binary lives in vcl-ut:
#   cd vcl-ut/src/interface/parse && cargo build --bin vclt-gate

set -euo pipefail

GATE="${VCLT_GATE:-}"

say()     { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
ok()      { printf '\033[32m  ✓ %s\033[0m\n' "$*"; }
bad()     { printf '\033[31m  ✗ %s\033[0m\n' "$*"; }
show()    { printf '    %s\n' "$*"; }
showjq()  { echo "$1" | jq -C . 2>/dev/null || echo "$1"; }

# ── Locate gate binary ────────────────────────────────────────────────────────
if [ -z "$GATE" ]; then
  # Try sibling vcl-ut repo first
  SIBLING="$(dirname "$(dirname "$(readlink -f "$0")")")"
  VCLT_BUILD="${SIBLING}/../vcl-ut/src/interface/parse/target/debug/vclt-gate"
  if [ -x "$VCLT_BUILD" ]; then
    GATE="$(realpath "$VCLT_BUILD")"
  elif command -v vclt-gate &>/dev/null; then
    GATE="vclt-gate"
  fi
fi

if [ -z "$GATE" ] || [ ! -x "$GATE" ]; then
  printf '\033[33mvclt-gate not found.\033[0m\n'
  printf 'Build it with:\n'
  printf '  cd vcl-ut/src/interface/parse && cargo build --bin vclt-gate\n'
  printf 'Then re-run or export VCLT_GATE=/path/to/binary.\n'
  exit 1
fi

say "Gate binary"
show "path: $GATE"
show "version probe:"
echo '{"schema_version":1,"statement":"SELECT GRAPH FROM HEXAD probe","schema":{}}' \
  | "$GATE" | jq -r '"  certified_level=\(.certified_level) admissible=\(.admissible)"'

# ── Helper: run one statement through the gate ────────────────────────────────
run_gate() {
  local label="$1"; local stmt="$2"
  local payload; payload=$(jq -n --arg s "$stmt" '{"schema_version":1,"statement":$s,"schema":{}}')
  local out code=0
  out=$(echo "$payload" | "$GATE" 2>/dev/null) || code=$?
  local level; level=$(echo "$out" | jq -r '.certified_level // -1')
  local reasons; reasons=$(echo "$out" | jq -r '.reasons[]? // empty' | head -3)
  if [ "$code" -eq 0 ]; then
    ok "$label  →  admit (level $level)"
  elif [ "$code" -eq 1 ]; then
    bad "$label  →  reject (level $level)"
    while IFS= read -r r; do show "    $r"; done <<< "$reasons"
  else
    bad "$label  →  gate_failed (exit $code)"
  fi
}

# ── Admitted: well-formed VCL statements ────────────────────────────────────
say "Admitted statements"

run_gate "SELECT GRAPH" \
  "SELECT GRAPH FROM HEXAD drone007"

run_gate "SELECT multi-modality" \
  "SELECT DOCUMENT, GRAPH FROM HEXAD drone007"

run_gate "SELECT with explicit LIMIT" \
  "SELECT GRAPH FROM HEXAD drone007 LIMIT 100"

run_gate "SELECT VECTOR" \
  "SELECT VECTOR FROM HEXAD sensor42"

# ── Rejected: structurally malformed or unsafe statements ────────────────────
say "Rejected statements (gate exits 1 — never reach the store)"

run_gate "Trailing-token injection" \
  "SELECT GRAPH FROM HEXAD abc; DROP TABLE hexads"

run_gate "Chained OR injection" \
  "SELECT GRAPH FROM HEXAD abc WHERE id == '1' OR '1'=='1'"

run_gate "Non-integer LIMIT" \
  "SELECT GRAPH FROM HEXAD abc LIMIT not_a_number"

run_gate "Missing source identifier" \
  "SELECT GRAPH FROM HEXAD"

# ── Summary ──────────────────────────────────────────────────────────────────
say "Protocol summary"
show "exit 0  →  :admit     (statement is structurally safe)"
show "exit 1  →  {:reject, reasons}  (violation detected before execution)"
show "exit 2  →  {:error, :gate_failed}  (gate itself failed)"
show ""
show "Set VERISIM_VCLT_GATE=<path> to wire this gate into VeriSimDB's"
show "VCL executor (queries bypass gate; mutations always pass through)."
