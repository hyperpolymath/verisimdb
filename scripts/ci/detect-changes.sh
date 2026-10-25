#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# detect-changes.sh — single source of truth for "did this PR touch <pattern>?"
#
# Usage (in a workflow step):
#   - name: Detect relevant changes
#     id: detect
#     env:
#       GH_TOKEN: ${{ github.token }}
#       EVENT_NAME: ${{ github.event_name }}
#       PR_NUMBER: ${{ github.event.pull_request.number }}
#       REPOSITORY: ${{ github.repository }}
#     run: bash scripts/ci/detect-changes.sh '^elixir-orchestration/'
#
# Writes relevant=true|false to $GITHUB_OUTPUT. On non-PR events everything is
# relevant. This exists so path-filtered jobs can still REPORT on every PR
# (a never-reporting required check deadlocks the merge gate — the
# cicd-squabbler path-filter-deadlock class). No ${{ }} expansion happens
# inside this script; callers pass context through env: only.
set -euo pipefail

PATTERN="${1:?usage: detect-changes.sh <extended-regex>}"
OUT="${GITHUB_OUTPUT:-/dev/stdout}"

if [ "${EVENT_NAME:-}" = "pull_request" ]; then
  FILES="$(gh api "repos/${REPOSITORY}/pulls/${PR_NUMBER}/files" --paginate --jq '.[].filename')"
  if printf '%s\n' "$FILES" | grep -qE "$PATTERN"; then
    echo "relevant=true" >> "$OUT"
  else
    echo "relevant=false" >> "$OUT"
    echo "No files match ${PATTERN} — pass-through (required-check shim)."
  fi
else
  echo "relevant=true" >> "$OUT"
fi
