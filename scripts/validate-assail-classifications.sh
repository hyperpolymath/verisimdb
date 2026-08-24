#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Validate panic-attack's (file, category) classification keys.

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REGISTRY=${1:-audits/assail-classifications.a2ml}

if [[ "$REGISTRY" != /* ]]; then
    REGISTRY="$REPO_ROOT/$REGISTRY"
fi

if [[ ! -f "$REGISTRY" ]]; then
    echo "ERROR: classification registry does not exist: $REGISTRY" >&2
    exit 1
fi

PAIRS=$(mktemp "${TMPDIR:-/tmp}/verisimdb-assail-pairs.XXXXXX")
SORTED=$(mktemp "${TMPDIR:-/tmp}/verisimdb-assail-sorted.XXXXXX")
trap 'rm -f -- "$PAIRS" "$SORTED"' EXIT

awk '
  /^[[:space:]]*\(classification([[:space:]]|$)/ { classifications++ }
  /^[[:space:]]*\(file[[:space:]]+"[^"]+"\)/ {
    value = $0
    sub(/^[[:space:]]*\(file[[:space:]]+"/, "", value)
    sub(/"\).*$/, "", value)
    pending_file = value
    files++
  }
  /^[[:space:]]*\(category[[:space:]]+"[^"]+"\)/ {
    value = $0
    sub(/^[[:space:]]*\(category[[:space:]]+"/, "", value)
    sub(/"\).*$/, "", value)
    categories++
    if (pending_file == "") {
      print "ERROR: category without a preceding file at line " NR > "/dev/stderr"
      malformed = 1
    } else {
      print pending_file "\t" value
      pending_file = ""
    }
  }
  END {
    if (classifications == 0 || files != classifications || categories != classifications || pending_file != "") {
      print "ERROR: expected exactly one file and category per classification; classifications=" classifications ", files=" files ", categories=" categories > "/dev/stderr"
      exit 1
    }
    if (malformed) exit 1
  }
' "$REGISTRY" > "$PAIRS"

status=0
while IFS=$'\t' read -r file category; do
    case "$file" in
        /*|../*|*/../*|*/..)
            echo "ERROR: classification path must stay within the repository: $file ($category)" >&2
            status=1
            ;;
        *)
            if [[ ! -f "$REPO_ROOT/$file" ]]; then
                echo "ERROR: classification target does not exist: $file ($category)" >&2
                status=1
            fi
            ;;
    esac
done < "$PAIRS"

sort "$PAIRS" > "$SORTED"
while IFS= read -r duplicate; do
    [[ -z "$duplicate" ]] && continue
    echo "ERROR: duplicate classification key: $duplicate" >&2
    status=1
done < <(uniq -d "$SORTED")

if (( status != 0 )); then
    exit "$status"
fi

count=$(wc -l < "$PAIRS")
echo "assail classification registry valid: $count file/category keys resolve"
