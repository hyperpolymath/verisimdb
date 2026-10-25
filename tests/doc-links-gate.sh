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

# PR #320 adds a handover and its index entry. The link checker above checks
# paths, but intentionally skips <<anchor,label>> references. Check this
# document's explicit anchors here without assuming generated section IDs.
HANDOVER="$REPO_ROOT/docs/HANDOVER-2026-10-24.adoc"
INDEX="$REPO_ROOT/docs/INDEX.adoc"

check_handover_navigation() {
    local handover=$1 index=$2
    awk '
      /^==== / { handovers = ($0 == "==== Handovers") }
      handovers && /link:HANDOVER-2026-10-24\.adoc\[/ { entries++ }
      END {
        if (entries != 1) {
          print "ERROR: expected one handover link in the Handovers section"
          exit 1
        }
      }
    ' "$index" || return 1

    awk '
      /^\[\[[a-z][a-z0-9-]*\]\]$/ {
        id = $0
        sub(/^\[\[/, "", id)
        sub(/\]\]$/, "", id)
        anchors[id]++
      }
      {
        rest = $0
        while (match(rest, /<<[a-z][a-z0-9-]*[,>]/)) {
          id = substr(rest, RSTART + 2, RLENGTH - 3)
          references[id]++
          count++
          rest = substr(rest, RSTART + RLENGTH)
        }
      }
      END {
        if (!count) {
          print "ERROR: handover has no internal references to check"
          failed = 1
        }
        for (id in references) {
          if (!(id in anchors)) {
            print "ERROR: unresolved handover anchor: " id
            failed = 1
          }
        }
        for (id in anchors) {
          if (anchors[id] != 1) {
            print "ERROR: duplicate handover anchor: " id
            failed = 1
          }
        }
        exit failed
      }
    ' "$handover"
}

echo "checking handover discoverability and internal navigation..."
check_handover_navigation "$HANDOVER" "$INDEX"

# Positive controls use copies of the changed documents. Assert the diagnostic
# as well as exit status so an unrelated read/parse failure cannot pass.
expect_navigation_failure() {
    local handover=$1 index=$2 needle=$3 output result=0
    output=$(check_handover_navigation "$handover" "$index" 2>&1) || result=$?
    if (( result != 1 )) || [[ "$output" != *"$needle"* ]]; then
        echo "ERROR: expected navigation failure: $needle" >&2
        echo "$output" >&2
        exit 1
    fi
}

sed '/^\[\[verdict\]\]$/d' "$HANDOVER" > "$FIXTURE_DIR/missing-anchor.adoc"
expect_navigation_failure "$FIXTURE_DIR/missing-anchor.adoc" "$INDEX" \
    "unresolved handover anchor: verdict"

cp "$HANDOVER" "$FIXTURE_DIR/duplicate-anchor.adoc"
printf '\n[[verdict]]\n' >> "$FIXTURE_DIR/duplicate-anchor.adoc"
expect_navigation_failure "$FIXTURE_DIR/duplicate-anchor.adoc" "$INDEX" \
    "duplicate handover anchor: verdict"

sed '/link:HANDOVER-2026-10-24\.adoc\[/d' "$INDEX" > "$FIXTURE_DIR/missing-entry.adoc"
expect_navigation_failure "$HANDOVER" "$FIXTURE_DIR/missing-entry.adoc" \
    "expected one handover link in the Handovers section"

# The quoted HEXAD production is evidence for the legacy-alias explanation.
# Compare the actual snippet with both grammar copies, not a copied expectation.
echo "checking the handover grammar example against both grammar sources..."
mapfile -t productions < <(sed -n '/^hexad_source = /p' "$HANDOVER")
if (( ${#productions[@]} != 1 )); then
    echo "ERROR: expected one HEXAD production in the handover" >&2
    exit 1
fi
for grammar in spec/grammar.ebnf docs/vcl-grammar.ebnf; do
    if ! grep -qxF -- "${productions[0]}" "$REPO_ROOT/$grammar"; then
        echo "ERROR: handover HEXAD example differs from $grammar" >&2
        exit 1
    fi
done

# Exercise the new Reproduce block with the real gates. Only these reviewed,
# short, local commands may run: never evaluate arbitrary documentation as shell.
echo "checking and running the handover reproduction instructions..."
mapfile -t commands < <(awk '
  /^== .*Reproduce$/ { reproduce = 1; next }
  reproduce && /^== / { exit }
  reproduce && /^----$/ { block++; next }
  reproduce && block == 1 && NF { print }
' "$HANDOVER")
expected=(
    "bash tests/doc-consonance-gate.sh"
    "bash scripts/check-doc-links.sh"
    "python3 scripts/check-modality-contract.py"
    "bash tests/modality-contract-gate.sh"
    "bash tests/assail-classifications-gate.sh"
)
if (( ${#commands[@]} != ${#expected[@]} )); then
    echo "ERROR: Reproduce must list all five verification commands" >&2
    exit 1
fi
for expected_command in "${expected[@]}"; do
    matches=0
    for documented_command in "${commands[@]}"; do
        if [[ "$documented_command" == "$expected_command" ]]; then
            matches=$((matches + 1))
        fi
    done
    if (( matches != 1 )); then
        echo "ERROR: Reproduce must list exactly once: $expected_command" >&2
        exit 1
    fi
done
(
    cd "$REPO_ROOT"
    for documented_command in "${commands[@]}"; do
        read -r interpreter script <<< "$documented_command"
        "$interpreter" "$script"
    done
)

echo "PASS handover: index, internal anchors, grammar example and all five reproduction commands"
