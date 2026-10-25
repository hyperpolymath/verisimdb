#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# test-evidence.sh — the proven-tests-and-benches discipline, enforced on the
# native suites: every test/bench file in this repo must be registered in
# verification/test-registry.json with a provenance tier
# (actually-proven | provisionally-proven | unproven), a category and an
# aspect from the framework's lattice. Coverage claims are DERIVED from this
# registry intersected with files that exist — a registered-but-deleted file,
# or an existing-but-unregistered test, fails the gate. A claim cannot be
# faked by editing prose (TESTING.adoc renders from this registry's numbers).
#
# Usage: test-evidence.sh [--summary-only]
# Exit 0 = registry and tree agree; 1 = drift; 2 = gate could not look.
set -euo pipefail

cd "$(dirname "$0")/../.."
REG="verification/test-registry.json"
command -v jq >/dev/null 2>&1 || { echo "test-evidence: jq not on PATH" >&2; exit 2; }
[ -f "$REG" ] || { echo "test-evidence: $REG missing" >&2; exit 2; }
jq -e . "$REG" >/dev/null || { echo "test-evidence: $REG is not valid JSON" >&2; exit 2; }

# Discover every test / bench / fuzz / proof artefact in the tree.
mapfile -t FOUND < <(
  { find rust-core benches fuzz tests formal verification \
      \( -name '*_test.rs' -o -name '*_tests.rs' -o -name 'test_*.rs' \
         -o -name 'integration_test.rs' -o -name 'property_tests.rs' \
         -o -name 'snapshot_tests.rs' -o -name '*_benchmarks.rs' \
         -o -name 'fuzz_*.rs' -o -name '*.v' -o -name '*-gate.sh' \
         -o -name '*.idr' \) -type f 2>/dev/null
    find elixir-orchestration/test elixir-orchestration/bench \
      \( -name '*_test.exs' -o -name '*_bench.exs' \) -type f 2>/dev/null
  } | sort -u)

mapfile -t REGISTERED < <(jq -r '.suites[].files[]' "$REG" | sort -u)

fail=0
# Existing but unregistered: invisible evidence is not evidence.
for f in "${FOUND[@]}"; do
  if ! printf '%s\n' "${REGISTERED[@]}" | grep -qxF "$f"; then
    echo "::error file=$f::test-evidence: test/bench file is not in $REG — register it with a tier, category and aspect"
    fail=1
  fi
done
# Registered but missing: claimed evidence that does not exist.
for f in "${REGISTERED[@]}"; do
  if [ ! -f "$f" ]; then
    echo "::error file=$REG::test-evidence: registered file $f does not exist — remove the claim or restore the file"
    fail=1
  fi
done
# Tier vocabulary is closed (proven-tests-and-benches Types.idr).
bad_tiers="$(jq -r '.suites[] | select(.tier | IN("actually-proven","provisionally-proven","unproven") | not) | .id' "$REG")"
if [ -n "$bad_tiers" ]; then
  echo "::error file=$REG::test-evidence: suites with invalid tier: $bad_tiers"
  fail=1
fi
# An actually-proven claim must name its proof artefact (the ladder).
no_ladder="$(jq -r '.suites[] | select(.tier=="actually-proven") | select((.proof // "")=="") | .id' "$REG")"
if [ -n "$no_ladder" ]; then
  echo "::error file=$REG::test-evidence: actually-proven suites without a proof artefact: $no_ladder"
  fail=1
fi

echo "== test evidence summary (derived, not declared) =="
jq -r '.suites | group_by(.tier)[] | "\(.[0].tier): \(length) suite(s), \([.[].files|length]|add) file(s)"' "$REG"
echo "files on disk: ${#FOUND[@]}; registered: ${#REGISTERED[@]}"
[ "$fail" -eq 0 ] && echo "test-evidence: registry and tree agree."
exit "$fail"
