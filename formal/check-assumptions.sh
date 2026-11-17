#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# check-assumptions.sh LABEL OUT_FILE ALLOWED_ERE
#
# Fail-closed whitelist guard over the output of `Print Assumptions`.
#
# Coq prints, per theorem, either "Closed under the global context" or an
# "Axioms:" header followed by one "name : type" record per assumption, with
# any continuation of a long type indented. This guard:
#
#   1. rejects a missing or empty OUT_FILE (a broken pipeline is not a pass);
#   2. rejects any unindented line that is not one of those three shapes, so
#      a record the parser does not recognise fails instead of being skipped;
#   3. reads assumption names as any run of non-space, non-colon characters,
#      so qualified (Classical_Prop.classic), primed and non-ASCII names are
#      all caught, not only [A-Za-z_][A-Za-z0-9_]*;
#   4. fails on any name that ALLOWED_ERE does not match exactly;
#   5. passes an empty name set only on an exact "Closed under the global
#      context" line, so blank or indented-only output is not a pass.
#
# POSIX sh and POSIX awk only (mawk is the Ubuntu default and is enough).

set -eu

if [ "$#" -ne 3 ]; then
    echo "usage: $0 LABEL OUT_FILE ALLOWED_ERE" >&2
    exit 2
fi
label=$1
out=$2
allowed=$3

if [ ! -s "$out" ]; then
    echo "ERROR($label): $out missing or empty" >&2
    exit 1
fi

record='^[^[:space:]:]+ :'

unparsed=$(awk -v rec="$record" '
    /^[[:space:]]/ || NF == 0 { next }
    $0 == "Axioms:" || $0 == "Closed under the global context" { next }
    $0 ~ rec { next }
    { print }
' "$out")
if [ -n "$unparsed" ]; then
    echo "ERROR($label): unparsed line(s) in $out (update this guard if Coq's format changed):" >&2
    printf '%s\n' "$unparsed" >&2
    exit 1
fi

names=$(awk -v rec="$record" '$0 ~ rec { print $1 }' "$out" | sort -u)

# An empty name set is legitimate only when every theorem is closed under the
# global context. It must therefore come with positive evidence, an exact
# "Closed under the global context" line, and with no "Axioms:" header: a
# file holding only blank or indented text parses to no names and must fail.
if [ -z "$names" ]; then
    if grep -qx 'Axioms:' "$out"; then
        echo "ERROR($label): 'Axioms:' present but no assumption parsed from $out" >&2
        exit 1
    fi
    if ! grep -qx 'Closed under the global context' "$out"; then
        echo "ERROR($label): no assumption record and no 'Closed under the global context' line in $out" >&2
        exit 1
    fi
fi

# grep -vx exits 1 when every name is allowed (the good case) and 2 on error;
# tolerate exactly status 1.
unexpected=$(printf '%s\n' "$names" | grep -vxE "$allowed" || test "$?" -eq 1)
if [ -n "$unexpected" ]; then
    echo "ERROR($label): unexpected assumption(s) in $out:" >&2
    printf '%s\n' "$unexpected" >&2
    exit 1
fi

echo "OK($label): assumptions within whitelist"
