#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# doc-links-gate.sh — positive-control test for the relative-link gate.
#
# Same shape as tests/assail-classifications-gate.sh: run the real gate first,
# then plant a known-bad fixture in a scratch tree and assert the gate (a) fails
# and (b) fails for the RIGHT reason. A gate that rejects everything would pass
# test (a) alone; the reason-match is what makes this a positive control rather
# than a smoke test.
#
# WHY: on 2026-09-27 the tree carried 66 broken relative links, 43 of them
# `.md` -> `.adoc` renames that were never propagated. Nothing caught them.
# This test exists so that the thing which now catches them is itself caught if
# it stops working.

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CHECKER="$REPO_ROOT/scripts/check-doc-links.sh"
FIXTURE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/verisimdb-doc-links.XXXXXX")
trap 'rm -rf -- "$FIXTURE_DIR"' EXIT

if [[ ! -x "$CHECKER" ]]; then
    echo "ERROR: checker is not executable: $CHECKER" >&2
    exit 1
fi

# --- 1. The real tree must pass ------------------------------------------------
echo "[1/4] checking the working tree..."
"$CHECKER" "$REPO_ROOT"

# --- 2. Plant a broken link in a scratch tree ---------------------------------
echo "[2/4] planting a known-broken relative link..."
mkdir -p "$FIXTURE_DIR/docs"
cat > "$FIXTURE_DIR/docs/planted.adoc" <<'EOF'
= Planted fixture
:toc: left

A link that resolves, and one that does not.

* link:real-target.adoc[this one exists]
* link:RENAMED-AWAY.md[this one does not]
EOF
cat > "$FIXTURE_DIR/docs/real-target.adoc" <<'EOF'
= Real target
EOF

# --- 3. Assert it FAILS -------------------------------------------------------
echo "[3/4] asserting the gate rejects it..."
set +e
output=$("$CHECKER" "$FIXTURE_DIR" 2>&1)
result=$?
set -e

if (( result == 0 )); then
    echo "ERROR: link gate accepted a planted broken link" >&2
    echo "       A gate that passes this is not checking anything." >&2
    exit 1
fi

# --- 4. Assert it fails for the RIGHT reason ----------------------------------
echo "[4/4] asserting it failed for the right reason..."
if [[ "$output" != *"link:RENAMED-AWAY.md"* ]]; then
    echo "ERROR: gate failed but did not name the planted target" >&2
    echo "       (it may be failing on something unrelated, which is not a pass)" >&2
    echo "--- gate output ---" >&2
    echo "$output" >&2
    exit 1
fi

if [[ "$output" != *"docs/RENAMED-AWAY.md"* ]]; then
    echo "ERROR: gate did not report the resolved missing path" >&2
    echo "--- gate output ---" >&2
    echo "$output" >&2
    exit 1
fi

# The sibling link must NOT be reported: a checker that flags everything is not a
# checker, and this is the assertion that distinguishes the two.
if [[ "$output" == *"real-target.adoc"* ]]; then
    echo "ERROR: gate flagged a link that DOES resolve — it is over-reporting" >&2
    echo "--- gate output ---" >&2
    echo "$output" >&2
    exit 1
fi

echo "positive control passed:"
echo "  - the working tree resolves"
echo "  - a planted broken link is rejected"
echo "  - the rejection names the planted target and its resolved path"
echo "  - a resolving sibling link in the same file is NOT flagged"
