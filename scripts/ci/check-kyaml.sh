#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# check-kyaml.sh — KYAML (estate YAML policy Y-3, ruling D280) gate.
#
# Two lanes, mirroring the I-JSON/JCS adoption pattern in standards:
#   1. REPORT-ONLY: every *.yml/*.yaml in the repo is listed with its KYAML
#      status; this lane never fails the job. It exists so the remaining
#      migration surface is always measured, never assumed.
#   2. BLOCKING: files listed in scripts/ci/kyaml-converted.txt were
#      converted under an owner ruling and must STAY canonical KYAML.
#      Fix a failure with: bash scripts/ci/kyaml-format.sh <file>
#
# The formatter itself is vendored verbatim from hyperpolymath/standards
# (scripts/ci/kyaml-format.sh); its rewriter is `yq -p yaml -o kyaml '.'`,
# the one rewriter covered by the standards comment-preservation proof.
# Exit 2 = the gate could not look (no yq): never report that as a pass.
set -euo pipefail

cd "$(dirname "$0")/../.."
command -v yq >/dev/null 2>&1 || { echo "check-kyaml: yq not on PATH" >&2; exit 2; }

echo "== KYAML report-only scan (all YAML) =="
# shellcheck disable=SC2046
bash scripts/ci/kyaml-format.sh --check \
  $(find . -path ./.git -prune -o -type f \( -name '*.yml' -o -name '*.yaml' \) -print | sort) \
  || echo "::warning::KYAML report-only: non-KYAML files remain (see list above); migration is sequenced in docs/CI-CD.adoc"

echo "== KYAML converted-stay-canonical (blocking) =="
mapfile -t CONVERTED < <(grep -v '^[[:space:]]*\(#\|$\)' scripts/ci/kyaml-converted.txt)
if [ "${#CONVERTED[@]}" -eq 0 ]; then
  echo "check-kyaml: FATAL: converted list is empty — a vacuous gate is not a gate" >&2
  exit 2
fi
bash scripts/ci/kyaml-format.sh --check "${CONVERTED[@]}"
echo "KYAML: ${#CONVERTED[@]} converted file(s) canonical."
