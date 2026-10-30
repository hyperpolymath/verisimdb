## Add `packages/JuliaPackageSpitter.jl/` mirror (renamed from `JuliaPackage-Reuse-Audit.jl`) — additive, no history rewritten

The standalone repository was renamed 2026-10-04 (decision recorded in the
standalone repo's `docs/decisions/0002-reconcile-repository-and-package-name.adoc`).
This monorepo still mirrors it only under the retired directory name
`packages/JuliaPackage-Reuse-Audit.jl/`, and the name-joining consumer
`.github/workflows/package-drift.yml` (which derives the standalone clone URL
from the `packages/` directory name) resolves that directory only via GitHub's
ephemeral rename redirect.

### What this PR does (additive — the obvious action, renaming the directory, is the wrong one)

1. **Adds** `packages/JuliaPackageSpitter.jl/` — a full snapshot of standalone
   HEAD `a834b56` (2026-10-22; 193 files, same full-snapshot shape as the other
   34 package directories) plus `RENAME-NOTICE.adoc` recording the relationship
   (old dir preserved, source of truth, both names = one package/uuid).
2. **Repoints live docs** at the current directory, per the PR #27 precedent for
   the earlier renames: `REGISTRY-SUBMISSIONS.adoc` (entry 16 heading + subdir),
   `packages/Hyperpolymath.jl/README.adoc` (universal-graph link), and the
   `EXPLAINME.adoc` evidence line (35 directories / 34 packages, with the
   dual-mirror explained).
3. **Leaves untouched**: `packages/JuliaPackage-Reuse-Audit.jl/` byte-for-byte
   (it is the historical snapshot of the repo as it was then, and its
   `.machine_readable/` descriptiles are part of that record).
4. **Leaves `package-drift.yml` untouched**: it is report-only by design ("never
   auto-fixes, never picks a canonical side"). It now has a live, comparable
   target under the current name; the old directory will report drift (true —
   its snapshot predates the rename-era changes in `src/`) and, if GitHub ever
   drops the rename redirect, "remote unreachable" — also a true statement
   about a retired name.

### Why alias, not rename-in-place

* The directory name is a **key, not a label**: `package-drift.yml` joins
  `packages/<name>/` → `github.com/hyperpolymath/<name>`, and the sister store
  `verisimdb-data` keys its scans on the same name (see the companion PR there).
  Renaming the directory in place would cut the timeline in half for every
  name-keyed consumer and rewrite history — the old snapshot really was of a
  repository called `JuliaPackage-Reuse-Audit.jl`.
* The rename convention already exists estate-wide; this PR follows it rather
  than inventing one: the CLADE schema's `[status] aliases` /
  `[lineage] previous-names` (doctrine in this package's own CLADE: "a rename is
  NOT a phase change — the old prefixed-name goes to aliases[]"), and the
  2026-06-30 `standards/0-canon/CANONICAL-NAMES.adoc` mandate (deprecated forms
  remain in "explicit migration inputs, historical records"). The explicit
  relationship is recorded in `RENAME-NOTICE.adoc`.

### Generator check (per filing: "if the mirror is generated, the generator is what changed")

**The mirror is not auto-regenerated — verified, so the snapshot edit is the
change, and it is durable:**

* Git history of `packages/JuliaPackage-Reuse-Audit.jl/` is owner-authored
  campaign PRs only (no bot authors) — the estate-standardization campaigns are
  how every package directory in this monorepo is maintained.
* `mirror.yml` (in the snapshot and `standards/mirror-reusable.yml`) mirrors
  the **standalone** repo to external forges (gitlab/bitbucket/codeberg/
  sourcehut/disroot/gitea/radicle) — it never writes into this monorepo.
* `instant-sync.yml` dispatches to `hyperpolymath/.git-private-farm` for forge
  propagation with the repo name in the payload; that repo is **private and not
  readable from this session** (separate grant needed to verify its gitbots).
  GitHub's rename redirect keeps the old-name payload resolving for now —
  flagged, not fixable from here.
* `package-drift.yml` is explicitly report-only.

### Current estate-wide occurrence counts (re-run 2026-10-30, attached per filing)

Query (GitHub code search; `total_count` = matching files):

```
gh api "search/code?q=org:hyperpolymath+JuliaPackage-Reuse-Audit.jl"  → total_count = 70   (filing: 81)
gh api "search/code?q=org:hyperpolymath+JuliaPackageSpitter"          → total_count = 38   (filing: 27)
```

Retired name by repo (70 files): `JuliaPackageSpitter.jl` (standalone, own tree
mid-cleanup) 41 · `julia-ecosystem` 7 · `verisimdb-data` 3 · `gitbot-fleet` 3 ·
`gv-clade-index` 3 · `hypatia` 3 · `launch-scaffolder` 3 · `panic-attack` 2 ·
`reposystem` 2 · `contractiles` 1 · `julia-professional-registry` 1 ·
`oikosbot-estate` 1.
New name by repo (38 files): `JuliaPackageSpitter.jl` 16 · `julia-ecosystem` 11 ·
`Hyperpolymath.jl` 4 · `mathesis` 4 · `julia-professional-registry` 3.

Line-level in this repo (`grep -rI`, 2026-10-30): 14 lines retired name
(mirror snapshot `.machine_readable/` 11 — historical, kept; the two live-doc
lines repointed by this PR) · 18 lines new name (the snapshot's
`Project.toml`/`src/` were already named `JuliaPackageSpitter` — only the
repository was renamed).

### Acceptance

- [x] Current estate-wide occurrence counts attached, with the query used.
- [x] Chosen approach (alias vs tombstone vs regenerate) justified against the
      consumers of this store (`package-drift.yml` name-join, monorepo docs,
      sister `verisimdb-data` store, CLADE registry) — above.
- [x] Old key still resolves (`packages/JuliaPackage-Reuse-Audit.jl/`
      byte-for-byte, incl. its descriptiles); new key present
      (`packages/JuliaPackageSpitter.jl/` + drift-comparable essentials);
      relationship recorded (`RENAME-NOTICE.adoc`).
- [x] No historical record rewritten or deleted.
- [x] Mirror generator investigated: not auto-generated (campaign PRs);
      snapshot + notice is the durable change; the report-only drift workflow
      now has a live target under the current name.

### Follow-ups found (separate grants/repos, not touched here)

* `gv-clade-index` (the registry's one declaration site) still carries the
  retired name in `worker/data/index.json`, `worker/data/repos.json`,
  `verisim/seed/repos.a2ml` — zero hits for the new name.
* The standalone's `CLADE.a2ml` still declares the old `canonical-name` with
  `aliases = []` (its own doctrine: old prefixed-name → `aliases[]`); its
  identity gate currently fails with 189 occurrences outside the allowlist —
  the in-flight ADR 0002 cleanup is the right home.
* `standards/0-canon/CANONICAL-NAMES.adoc` has no deprecated-names row for
  this rename.
* `hyperpolymath/.git-private-farm` (instant-sync propagation target) is
  private — separate read grant needed to verify its gitbots' name handling.
