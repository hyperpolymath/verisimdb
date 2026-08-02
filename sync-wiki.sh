#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# sync-wiki.sh — mirror docs/ + top-level project documents to the
# GitHub wiki for hyperpolymath/verisimdb.
#
# How GitHub wikis work:
#   - The wiki is a separate git repo at github.com/<owner>/<repo>.wiki.git
#   - Page filenames map to wiki URLs:  Foo-Bar.md → /wiki/Foo-Bar
#   - GitHub wikis are flat (no subdirs in nav); we encode hierarchy in
#     the filename with hyphens (Architecture-Topology.md, etc.)
#   - Home.md is the landing page
#   - _Sidebar.md provides the navigation column
#   - _Footer.md is the per-page footer
#   - Both .md and .adoc are rendered server-side; we standardise on
#     copying as-is and let GitHub render the original format.
#
# Run from the repo root:
#   ./sync-wiki.sh                # idempotent sync, --no-push
#   ./sync-wiki.sh --push         # also git push to origin
#   ./sync-wiki.sh --dry-run      # show what would change
#
# Requirements:
#   - Git authenticated for the verisimdb.wiki.git remote (HTTPS PAT or SSH key)
#   - Standard POSIX tools: bash, find, sed, sort
#
# Idempotent: re-runs replace the same set of pages; nothing else is touched.

set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

WIKI_REMOTE="${WIKI_REMOTE:-git@github.com:hyperpolymath/verisimdb.wiki.git}"
WIKI_BRANCH="${WIKI_BRANCH:-master}"   # GitHub wikis default to 'master'
COMMIT_AUTHOR_NAME="${COMMIT_AUTHOR_NAME:-Wiki Sync Bot}"
COMMIT_AUTHOR_EMAIL="${COMMIT_AUTHOR_EMAIL:-noreply@hyperpolymath.local}"

PUSH=0
DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --push)    PUSH=1 ;;
        --dry-run) DRY_RUN=1 ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# *//'
            exit 0
            ;;
        *)
            echo "unknown arg: $arg" >&2
            exit 2
            ;;
    esac
done

# Resolve repo root robustly whether run from root or elsewhere.
REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO_ROOT"

if [ ! -d docs ]; then
    echo "error: docs/ not found at $REPO_ROOT" >&2
    exit 1
fi

WIKI_WORK="$(mktemp -d -t verisimdb-wiki-XXXXXX)"
trap 'rm -rf "$WIKI_WORK"' EXIT

# ---------------------------------------------------------------------------
# Step 1: clone or initialise the wiki repo
# ---------------------------------------------------------------------------

echo "==> cloning $WIKI_REMOTE → $WIKI_WORK"

if git clone --depth=1 --branch="$WIKI_BRANCH" "$WIKI_REMOTE" "$WIKI_WORK" 2>/dev/null; then
    :
else
    # First-time sync: wiki may not exist yet on GitHub, or the default
    # branch may differ. Initialise locally and we'll push to create it.
    echo "==> clone failed (wiki may not exist yet); initialising fresh"
    rm -rf "$WIKI_WORK"
    mkdir -p "$WIKI_WORK"
    cd "$WIKI_WORK"
    git init -q -b "$WIKI_BRANCH"
    git remote add origin "$WIKI_REMOTE"
    cd "$REPO_ROOT"
fi

# Wipe the synced pages (anything we generate) but preserve any
# hand-edited pages that don't share our naming convention.
# Our convention: every synced page starts with a known prefix.
PREFIXES=(
    "Home"
    "_Sidebar"
    "_Footer"
    "Project-"
    "Architecture-"
    "Decisions-"
    "Deployment-"
    "Status-"
    "Releases-"
    "Papers-"
    "Visualizations-"
    "VQL-"
    "Operations-"
    "Specialized-"
    "Business-"
    "Design-"
)
for prefix in "${PREFIXES[@]}"; do
    find "$WIKI_WORK" -maxdepth 1 -type f \( -name "${prefix}*.md" -o -name "${prefix}*.adoc" \) -delete 2>/dev/null || true
done

# ---------------------------------------------------------------------------
# Step 2: copy top-level project docs (root files)
# ---------------------------------------------------------------------------

# (source, destination basename — without extension)
copy_root() {
    local src="$1"
    local dst="$2"
    local ext="${src##*.}"
    if [ -f "$src" ]; then
        cp "$src" "$WIKI_WORK/${dst}.${ext}"
        echo "  wrote ${dst}.${ext}"
    fi
}

echo "==> copying top-level project documents"
copy_root README.adoc          Project-README
copy_root ROADMAP.md           Project-Roadmap
copy_root CHANGELOG.adoc       Project-Changelog
copy_root TESTING.md           Project-Testing-And-Benchmarking
copy_root KNOWN-ISSUES.adoc    Project-Known-Issues
copy_root AUDIT.adoc           Project-Audit-Index
copy_root SECURITY.md          Project-Security-Policy
copy_root CONTRIBUTING.md      Project-Contributing
copy_root MAINTAINERS.adoc     Project-Maintainers
copy_root CODE_OF_CONDUCT.md   Project-Code-Of-Conduct

# ---------------------------------------------------------------------------
# Step 3: copy docs/ subtree, flattening to PathPrefix-FileName.ext
# ---------------------------------------------------------------------------

echo "==> copying docs/ subtree"

# Slug a docs/<subdir>/<file>.<ext> → <Subdir>-<File>.<ext> (Title-Case dirs,
# basename preserved minus path separators).
slug() {
    local rel="$1"
    # Strip leading docs/, split on /, Title-Case each segment except the
    # final one (the filename), join with '-'.
    rel="${rel#docs/}"
    local dir base
    dir="$(dirname "$rel")"
    base="$(basename "$rel")"

    if [ "$dir" = "." ]; then
        # File directly under docs/ — no prefix needed, just preserve the name.
        echo "$base"
        return
    fi

    local out=""
    IFS='/' read -ra parts <<<"$dir"
    for p in "${parts[@]}"; do
        # capitalise first letter; replace _ with -
        local cap="$(echo "${p:0:1}" | tr '[:lower:]' '[:upper:]')${p:1}"
        cap="${cap//_/-}"
        if [ -z "$out" ]; then out="$cap"; else out="$out-$cap"; fi
    done

    echo "${out}-${base}"
}

# Walk docs/, copying every .md / .adoc / .ebnf / .lgt / .tex file.  Skip
# binaries (.pdf, .html) — they live in-repo but aren't wiki-friendly;
# we link to them from the wiki landing page instead.
while IFS= read -r src; do
    rel="${src#./}"
    slugged="$(slug "$rel")"
    cp "$src" "$WIKI_WORK/$slugged"
    echo "  wrote $slugged"
done < <(
    cd "$REPO_ROOT"
    find docs -type f \( -name '*.md' -o -name '*.adoc' -o -name '*.ebnf' -o -name '*.lgt' -o -name '*.tex' \) \
        -not -path 'docs/.well-known/*' \
        | sort
)

# ---------------------------------------------------------------------------
# Step 4: Home.md landing page
# ---------------------------------------------------------------------------

cat > "$WIKI_WORK/Home.md" <<'HOME'
# VeriSimDB Wiki

> Auto-generated from [docs/](https://github.com/hyperpolymath/verisimdb/tree/main/docs)
> by [./sync-wiki.sh](https://github.com/hyperpolymath/verisimdb/blob/main/sync-wiki.sh).
> Do not edit pages here that match the synced naming convention
> (`Project-*`, `Architecture-*`, `Decisions-*`, etc.) — your edits will
> be overwritten on the next sync. Hand-edited pages with other names
> are preserved.

## Project

- [Project-README](Project-README) — what VeriSimDB is, install, first run
- [Project-Roadmap](Project-Roadmap) — criticality-ordered Phase 1–8 plan
- [Project-Changelog](Project-Changelog) — versioned history
- [Project-Testing-And-Benchmarking](Project-Testing-And-Benchmarking) — CI gates, property tests, fuzz corpus
- [Project-Known-Issues](Project-Known-Issues) — honest-gaps audit (25/25 resolved)
- [Project-Security-Policy](Project-Security-Policy)
- [Project-Audit-Index](Project-Audit-Index) — RSR audit-trail index
- [Project-Contributing](Project-Contributing)
- [Project-Maintainers](Project-Maintainers)
- [Project-Code-Of-Conduct](Project-Code-Of-Conduct)

## Architecture

- [Architecture-abi-ffi.md](Architecture-abi-ffi.md) — ABI/FFI contract (Rust ↔ Elixir ↔ Idris2)
- [Architecture-topology.md](Architecture-topology.md) — process topology and deployment shapes

## Decisions (ADR-style)

- [Decisions-rust-spark-stance.adoc](Decisions-rust-spark-stance.adoc) — why Rust over alternatives
- [Decisions-kraft-comparison.adoc](Decisions-kraft-comparison.adoc) — why KRaft for consensus
- [Decisions-proven-coherence.md](Decisions-proven-coherence.md) — proven library integration notes

## Deployment

- [Deployment-deployment.adoc](Deployment-deployment.adoc) — Podman, selur-compose, Containerfile
- [Deployment-void-setup.md](Deployment-void-setup.md) — Void Linux dev environment

## Status & implementation tracking

- [Status-planner.md](Status-planner.md) — verisim-planner status
- [Status-implementation-plan.adoc](Status-implementation-plan.adoc) — timeline-based V1–V5 plan

## Releases

- [Releases-v0.1.0-alpha.md](Releases-v0.1.0-alpha.md) — v0.1.0-alpha announcement

## Papers

- [Papers-whitepaper.md](Papers-whitepaper.md) — VeriSimDB whitepaper (Markdown)
- [Papers-arcvix-octad-data-model.tex](Papers-arcvix-octad-data-model.tex) — ARCVIX octad data-model paper (LaTeX source)
- [Papers-verisimdb-federated-consistency.adoc](Papers-verisimdb-federated-consistency.adoc)
- [Papers-verisimdb-idaptik-case-study.adoc](Papers-verisimdb-idaptik-case-study.adoc)

The whitepaper PDF and architecture HTML visualizations live in-repo
only — they're not wiki-friendly formats. View them at:
- [docs/papers/whitepaper.pdf](https://github.com/hyperpolymath/verisimdb/blob/main/docs/papers/whitepaper.pdf)
- [docs/visualizations/architecture.html](https://github.com/hyperpolymath/verisimdb/blob/main/docs/visualizations/architecture.html)

## VQL language

- [VCL-SPEC.adoc](VCL-SPEC.adoc) — full VCL specification
- [vcl-grammar.ebnf](vcl-grammar.ebnf) — formal EBNF (or browse the file in the repo)
- [VQL-getting-started.adoc](getting-started.adoc) — step-by-step setup
- [vcl-formal-semantics.adoc](vcl-formal-semantics.adoc) — operational semantics
- [vcl-type-system.adoc](vcl-type-system.adoc) — dependent types + bidirectional checking
- [vcl-examples.adoc](vcl-examples.adoc) — worked examples

…and many more under the synced page list — see the sidebar.

## Source code

| Path | Language | Purpose |
|---|---|---|
| `rust-core/` | Rust | Core database engine (8 modality stores + octad + drift + normalizer + api + planner) |
| `elixir-orchestration/` | Elixir | OTP orchestration (DriftMonitor, EntityServer, VQLExecutor, VQLBridge, SchemaRegistry, federation adapters) |
| `src/` | ReScript | VQL parser, type checker, federation registry |
| `playground/` | ReScript + HTML | VQL Playground web UI |
| `connectors/` | Multi | Federation adapters, client SDKs (Rust, V, Elixir, ReScript, Julia, Gleam), test infrastructure |
| `debugger/` | Idris2 + Rust | ABI/FFI debugger |
| `ffi/zig/` | Zig | Zig FFI |
| `v-api-gateway/` | V | V-language API gateway |
| `fuzz/`, `rust-core/fuzz/` | Rust | Fuzz harnesses (libFuzzer via cargo-fuzz) |
| `benches/` | Rust | Criterion benchmarks (all 8 modalities) |
| `elixir-orchestration/bench/` | Elixir | Benchee benchmark scripts |

## Editing the wiki

Anything matching `Project-*`, `Architecture-*`, `Decisions-*`,
`Deployment-*`, `Status-*`, `Releases-*`, `Papers-*`, `Visualizations-*`,
`VQL-*`, `Operations-*`, `Specialized-*`, `Business-*`, `Design-*`,
`Home.md`, `_Sidebar.md`, or `_Footer.md` is overwritten by the next
sync. Edit the source files in the repo and re-run
`./sync-wiki.sh --push`.

Hand-edited pages with other names are preserved.
HOME

echo "  wrote Home.md"

# ---------------------------------------------------------------------------
# Step 5: _Sidebar.md — navigation column
# ---------------------------------------------------------------------------

{
    echo '### [VeriSimDB](Home)'
    echo
    echo '**Project**'
    for p in "Project-README" "Project-Roadmap" "Project-Changelog" \
             "Project-Testing-And-Benchmarking" "Project-Known-Issues" \
             "Project-Audit-Index" "Project-Security-Policy" \
             "Project-Contributing" "Project-Maintainers" \
             "Project-Code-Of-Conduct"; do
        if ls "$WIKI_WORK"/${p}.* >/dev/null 2>&1; then
            echo "- [${p#Project-}](${p})"
        fi
    done

    echo
    echo '**Architecture & Decisions**'
    for f in "$WIKI_WORK"/Architecture-* "$WIKI_WORK"/Decisions-*; do
        [ -f "$f" ] || continue
        name="$(basename "$f")"
        page="${name%.*}"
        echo "- [${page}](${page})"
    done

    echo
    echo '**Deployment**'
    for f in "$WIKI_WORK"/Deployment-*; do
        [ -f "$f" ] || continue
        name="$(basename "$f")"
        page="${name%.*}"
        echo "- [${page}](${page})"
    done

    echo
    echo '**Status & Releases**'
    for f in "$WIKI_WORK"/Status-* "$WIKI_WORK"/Releases-*; do
        [ -f "$f" ] || continue
        name="$(basename "$f")"
        page="${name%.*}"
        echo "- [${page}](${page})"
    done

    echo
    echo '**Papers**'
    for f in "$WIKI_WORK"/Papers-*; do
        [ -f "$f" ] || continue
        name="$(basename "$f")"
        page="${name%.*}"
        echo "- [${page}](${page})"
    done
} > "$WIKI_WORK/_Sidebar.md"

echo "  wrote _Sidebar.md"

# ---------------------------------------------------------------------------
# Step 6: _Footer.md
# ---------------------------------------------------------------------------

cat > "$WIKI_WORK/_Footer.md" <<FOOTER
Synced from [docs/](https://github.com/hyperpolymath/verisimdb/tree/main/docs)
on $(date -u '+%Y-%m-%d %H:%M UTC').
Run \`./sync-wiki.sh --push\` to refresh.
FOOTER

echo "  wrote _Footer.md"

# ---------------------------------------------------------------------------
# Step 7: commit & (optionally) push
# ---------------------------------------------------------------------------

cd "$WIKI_WORK"

git add -A

if [ "$DRY_RUN" = "1" ]; then
    echo
    echo "==> --dry-run: changes that would be committed:"
    git --no-pager status --short
    echo
    echo "==> not committing.  Workspace at $WIKI_WORK (not auto-cleaned)."
    trap - EXIT
    exit 0
fi

if git diff --cached --quiet; then
    echo "==> wiki already up to date — nothing to commit."
    exit 0
fi

# Configure committer identity (won't override an existing global config).
git config user.name  "$COMMIT_AUTHOR_NAME"
git config user.email "$COMMIT_AUTHOR_EMAIL"

git commit -q -m "wiki: sync from docs/ ($(date -u '+%Y-%m-%d %H:%M UTC'))" \
              -m "Synced by ./sync-wiki.sh from the verisimdb repo."

echo "==> committed.  $(git --no-pager log -1 --oneline)"

if [ "$PUSH" = "1" ]; then
    echo "==> pushing to $WIKI_REMOTE"
    git push origin "$WIKI_BRANCH"
    echo "==> done."
else
    echo "==> not pushed (pass --push to push).  Local wiki at $WIKI_WORK"
    trap - EXIT
fi
