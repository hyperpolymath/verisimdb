#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# demo-consonance.sh — the VeriSimDB consonance loop, end to end, for real.
#
# Creates an entity whose document and graph disagree, shows the measured
# drift, asks the normalizer to repair it, and shows the drift fall to zero
# with the repair recorded on the provenance chain.
#
# Usage:
#   scripts/demo-consonance.sh            # starts a server on :8814, cleans up
#   VERISIM_PORT=8080 scripts/demo-consonance.sh   # reuse a running server
#
# Requires: curl, jq. Builds verisim-api via cargo if no server is running.

set -euo pipefail

PORT="${VERISIM_PORT:-8814}"
BASE="http://127.0.0.1:${PORT}"
SERVER_PID=""

say()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
show() { printf '%s\n' "$*"; }

cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

if ! curl -fsS "${BASE}/health" >/dev/null 2>&1; then
  say "Starting verisim-api on port ${PORT}"
  cargo build -p verisim-api --quiet
  VERISIM_HOST=127.0.0.1 VERISIM_PORT="$PORT" RUST_LOG=warn \
    ./target/debug/verisim-api &
  SERVER_PID=$!
  for _ in $(seq 1 60); do
    curl -fsS "${BASE}/health" >/dev/null 2>&1 && break
    sleep 0.5
  done
  curl -fsS "${BASE}/health" >/dev/null
fi

say "1. Create an entity whose document and graph DISAGREE"
show "   The document never mentions the graph relationship target."
ID=$(curl -fsS -X POST "${BASE}/octads" \
  -H 'content-type: application/json' \
  -d '{
    "title": "Mission Brief",
    "body": "A short note that does not mention its relation.",
    "relationships": [["relates_to", "project-aurora"]],
    "provenance": {
      "event_type": "created",
      "actor": "demo",
      "source": null,
      "description": "created by demo-consonance"
    }
  }' | jq -r '.id')
show "   entity id: ${ID}"

say "2. Measure drift for this entity (computed from its own modalities)"
curl -fsS "${BASE}/drift/entity/${ID}" | jq '{
  score, status,
  graph_document: (.components[] | select(.drift_type=="graph_document_drift") | {score, detail}),
  provenance:     (.components[] | select(.drift_type=="provenance_drift")     | {score, detail})
}'

say "3. Aggregate drift status (live measurements, not initialized zeros)"
curl -fsS "${BASE}/drift/status" | jq '[.[] | select(.measurement_count > 0) | {drift_type, current_score, measurement_count}]'

say "4. Ask the normalizer to repair it"
show "   It regenerates the document from the graph (the authoritative source)"
show "   and writes the repair back: versioned, WAL-logged, provenance-chained."
curl -fsS -X POST "${BASE}/normalizer/trigger/${ID}" | jq '{
  action, modality, source_modality, before_score, after_score
}'

say "5. Re-measure: the dissonance is gone"
curl -fsS "${BASE}/drift/entity/${ID}" | jq '{
  score, status,
  graph_document: (.components[] | select(.drift_type=="graph_document_drift") | {score, detail})
}'

say "6. The repair is on the audit trail"
curl -fsS "${BASE}/octads/${ID}" | jq '{id, version_count, provenance_chain_length}'
show ""
show "Consonance loop complete: dissonance created -> measured -> repaired -> re-measured."
