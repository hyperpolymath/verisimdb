#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# doc-consonance-gate.sh — fail-closed guard against the query-language
# misnomer in VeriSimDB documentation.
#
# VCL is the VeriSim *Consonance* Language: it expresses propositions
# (DECLARE/ASSERT/RETRACT) and epistemic requests (INSPECT/VERIFY) over
# identity-consonance state. "VeriSim Query Language" is a RETIRED misnomer
# (see README.adoc / EXPLAINME.adoc). This gate stops it creeping back into
# the docs.
#
# Scope: documentation only (*.adoc, *.md, *.a2ml). Code identifiers
# (vql_executor, /api/v1/vql/execute, VeriSimVql) and the bare "VQL" token in
# changelog/history are out of scope — they are tracked under the staged #84
# rename, and this gate must stay green meanwhile.
set -euo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'

# Files that legitimately name the legacy term: this gate, the changelog
# history, and the cross-thread quarantine directive (which explains it).
ALLOW='tests/doc-consonance-gate.sh|CHANGELOG|cross-thread-quarantine'

hits=$(git grep -n 'VeriSim Query Language' -- '*.adoc' '*.md' '*.a2ml' 2>/dev/null | grep -vE "$ALLOW" || true)

if [ -n "$hits" ]; then
  echo -e "${RED}FAIL${NC} doc-consonance: 'VeriSim Query Language' is a retired misnomer."
  echo "       Use 'VeriSim Consonance Language' (VCL). Offending lines:"
  echo "$hits" | sed 's/^/         /'
  exit 1
fi

echo -e "${GREEN}PASS${NC} doc-consonance: no 'VeriSim Query Language' misnomer in docs"
