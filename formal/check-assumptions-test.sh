#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# Self-test for check-assumptions.sh: each fixture is a hand-written
# `Print Assumptions` output and the verdict the guard must reach on it.

set -eu
here=$(cd "$(dirname "$0")" && pwd)
guard="$here/check-assumptions.sh"
allowed='mval|ident|functional_extensionality_dep'
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0

# expect NAME VERDICT(pass|fail) — fixture text on stdin
expect() {
    cat > "$tmp/$1.out"
    if sh "$guard" "$1" "$tmp/$1.out" "$allowed" >/dev/null 2>&1; then got=pass; else got=fail; fi
    if [ "$got" = "$2" ]; then
        echo "ok   $1 ($got)"
    else
        echo "FAIL $1: expected $2, got $got"
        fails=$((fails + 1))
    fi
}

expect allowed-only pass <<'EOF'
Axioms:
mval : Type
ident : Type
Axioms:
functional_extensionality_dep : forall (A : Type) (B : A -> Type)
  (f g : forall x : A, B x), (forall x : A, f x = g x) -> f = g
EOF

expect closed pass <<'EOF'
Closed under the global context
EOF

expect qualified-axiom fail <<'EOF'
Axioms:
mval : Type
Classical_Prop.classic : forall P : Prop, P \/ ~ P
EOF

expect primed-axiom fail <<'EOF'
Axioms:
ident' : Type
EOF

expect unicode-axiom fail <<'EOF'
Axioms:
mval : Type
π : R
EOF

expect unicode-qualified-axiom fail <<'EOF'
Axioms:
Réels.complétude : Prop
EOF

expect unparsed-record fail <<'EOF'
Axioms:
mval : Type
Section Variables:
EOF

expect empty fail </dev/null

expect axioms-header-no-records fail <<'EOF'
Axioms:
EOF

# Non-empty files that parse to no names and carry no closed-theorem line.
printf ' \n' | expect whitespace-only fail

expect indented-text-only fail <<'EOF'
  mval : Type
  some continuation text
EOF

if [ "$fails" -ne 0 ]; then
    echo "$fails guard self-test(s) failed" >&2
    exit 1
fi
echo "OK: check-assumptions.sh self-test"
