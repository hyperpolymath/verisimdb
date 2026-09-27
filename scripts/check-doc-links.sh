#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# check-doc-links.sh — fail-closed guard against broken relative links in docs.
#
# WHY THIS EXISTS
#   On 2026-09-27 the tree carried 66 broken relative links across *.adoc, 43 of
#   them `.md` -> `.adoc` renames that were never propagated to the documents
#   pointing at them. Nothing caught this: doc-consonance-gate.sh checks for a
#   banned *string*, and the estate governance `docs` job checks only that
#   README / LICENSE / CONTRIBUTING *exist*. A link to a file that was renamed is
#   invisible to both. This is the same failure shape as the assail
#   classification registry drift (issue #203): a rename silently invalidates a
#   reference, and the reference outlives the thing it pointed at.
#
# SCOPE
#   AsciiDoc `link:TARGET[...]` macros and Markdown `[text](TARGET)` links in
#   *.adoc and *.md tracked by git. Relative filesystem targets only.
#
#   Deliberately NOT checked:
#     * http/https/mailto — external, and a network probe in CI would make this
#       gate flaky and slow for no local benefit.
#     * in-document anchors (`link:#section`, `link:++#section++`, `xref:`) —
#       resolving an AsciiDoc section id to its generated anchor requires an
#       AsciiDoc processor, and a wrong answer here would be worse than no
#       answer. Fragment-only targets are skipped; a target with both a path and
#       a fragment has its *path* checked, which is the part that rots.
#     * `include::` directives — separate concern, separate gate.
#
# ALLOWLIST
#   Targets listed in scripts/doc-links-allowlist.txt are exempt. Each line needs
#   a `#` reason, because an unexplained exemption is how a gate stops meaning
#   anything. Blank lines and whole-line comments are ignored.
#
# USAGE
#   scripts/check-doc-links.sh              # check the working tree
#   scripts/check-doc-links.sh <root>       # check an alternate root (for tests)
#
# EXIT
#   0 — every relative link resolves (or is exempt with a reason)
#   1 — at least one broken link; the full list is printed

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCAN_ROOT=${1:-$REPO_ROOT}
ALLOWLIST="$REPO_ROOT/scripts/doc-links-allowlist.txt"

if [[ ! -d "$SCAN_ROOT" ]]; then
    echo "ERROR: scan root does not exist: $SCAN_ROOT" >&2
    exit 2
fi

if ! command -v python3 >/dev/null 2>&1; then
    # Fail closed. A missing interpreter must not read as a clean pass; that is
    # the same trap deny.toml warns about with an unpopulated advisory database.
    echo "ERROR: python3 missing on runner — cannot check doc links" >&2
    exit 2
fi

SCAN_ROOT="$SCAN_ROOT" ALLOWLIST="$ALLOWLIST" python3 - <<'PY'
import os
import re
import sys

root = os.environ["SCAN_ROOT"]
allowlist_path = os.environ.get("ALLOWLIST", "")

# AsciiDoc link macro: link:TARGET[text]  (TARGET cannot contain [ ] or whitespace)
ADOC_LINK = re.compile(r"(?<![\w:])link:([^\[\]\s]+)\[")
# Markdown inline link: [text](TARGET)
MD_LINK = re.compile(r"(?<!\!)\[[^\]\n]*\]\(([^)\s]+)")

EXTERNAL = ("http://", "https://", "mailto:", "ftp://", "//")


def load_allowlist(path):
    """Exempt targets, each requiring an inline `#` reason."""
    allowed = {}
    if not path or not os.path.isfile(path):
        return allowed
    with open(path, encoding="utf-8") as fh:
        for lineno, raw in enumerate(fh, 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if "#" not in line:
                print(
                    f"ERROR: {path}:{lineno}: allowlist entry has no `#` reason: {line}",
                    file=sys.stderr,
                )
                allowed.setdefault("__malformed__", []).append(line)
                continue
            target, reason = line.split("#", 1)
            target = target.strip()
            reason = reason.strip()
            if not target:
                continue
            if not reason:
                print(
                    f"ERROR: {path}:{lineno}: allowlist entry has an empty reason: {line}",
                    file=sys.stderr,
                )
                allowed.setdefault("__malformed__", []).append(line)
                continue
            allowed[target] = reason
    return allowed


def normalise(target):
    """Strip AsciiDoc passthrough markers, fragments and link attributes."""
    t = target.strip()
    # `link:++#anchor++[]` and `link:++path++[]` — AsciiDoc passthrough quoting.
    if t.startswith("++") and t.endswith("++"):
        t = t[2:-2]
    # Drop the fragment: the path is the part that rots on a rename.
    t = t.split("#", 1)[0]
    # Drop AsciiDoc link attributes that leaked into the target capture.
    t = t.split(",", 1)[0] if t.count(",") and not os.sep in t.split(",")[0] else t
    return t.strip()


def is_fragment_only(target):
    t = target.strip()
    if t.startswith("++") and t.endswith("++"):
        t = t[2:-2]
    return t.startswith("#")


allowed = load_allowlist(allowlist_path)
broken = []
checked = 0
exempt = 0

doc_paths = []
for dirpath, dirnames, filenames in os.walk(root):
    # Never walk into VCS or build output; those are not documentation and can
    # legitimately contain fixture text that looks like a link.
    dirnames[:] = [
        d
        for d in dirnames
        if d not in {".git", "_build", "_site", "node_modules", "target", "_deps", ".claude"}
    ]
    for name in filenames:
        if name.endswith((".adoc", ".md")):
            doc_paths.append(os.path.join(dirpath, name))

for path in sorted(doc_paths):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError as exc:
        print(f"ERROR: cannot read {path}: {exc}", file=sys.stderr)
        broken.append((path, "<unreadable>", str(exc)))
        continue

    base = os.path.dirname(path)
    patterns = (ADOC_LINK,) if path.endswith(".adoc") else (MD_LINK,)
    for pattern in patterns:
        for match in pattern.finditer(text):
            raw_target = match.group(1)
            if raw_target.startswith(EXTERNAL):
                continue
            if is_fragment_only(raw_target):
                continue
            target = normalise(raw_target)
            if not target:
                continue
            line_no = text.count("\n", 0, match.start()) + 1

            if target in allowed:
                exempt += 1
                continue

            resolved = os.path.normpath(os.path.join(base, target))
            checked += 1
            if os.path.exists(resolved):
                continue

            # A rename is the overwhelmingly common cause, so name the likely
            # fix rather than just reporting the miss.
            stem, ext = os.path.splitext(resolved)
            suggestion = ""
            for alt in (".adoc", ".md", ".pdf", ".html", ".txt", ".ttl", ".rdf", ""):
                if alt == ext:
                    continue
                if os.path.exists(stem + alt):
                    suggestion = f"  (did you mean `{os.path.relpath(stem + alt, root)}`?)"
                    break
            broken.append(
                (
                    os.path.relpath(path, root),
                    f"{line_no}: link:{raw_target}",
                    f"missing {os.path.relpath(resolved, root)}{suggestion}",
                )
            )

if allowed.get("__malformed__"):
    print("ERROR: allowlist is malformed; refusing to treat it as authoritative", file=sys.stderr)
    sys.exit(2)

if broken:
    print(f"FAIL doc-links: {len(broken)} broken relative link(s) in {len(doc_paths)} documents")
    for path, where, why in broken:
        print(f"  {path} {where} -> {why}")
    print()
    print("Fix the target, or add it to scripts/doc-links-allowlist.txt WITH a reason.")
    print("An exemption without a reason is how a gate stops meaning anything.")
    sys.exit(1)

print(
    f"PASS doc-links: {checked} relative link(s) resolve across {len(doc_paths)} documents"
    f" ({exempt} exempt with reason)"
)
PY
