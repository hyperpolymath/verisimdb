## Add scan key for `JuliaPackageSpitter.jl` (renamed from `JuliaPackage-Reuse-Audit.jl`) — additive, no history rewritten

The standalone repository was renamed 2026-10-04 (decision recorded in the
standalone repo's `docs/decisions/0002-reconcile-repository-and-package-name.adoc`).
This store still keys only on the retired name: `scans/JuliaPackage-Reuse-Audit.jl.json`
plus its `index.json` entry.

### What this PR does (additive alias — the obvious action, renaming the file, is the wrong one)

1. **Adds** `scans/JuliaPackageSpitter.jl.json` — the last scan of this code
   re-keyed under the new name, with explicit provenance fields
   `renamed_from`, `renamed_at` (`2026-10-04`), `rename_decision`, and a `note`.
   Verified byte-identical to the old record's data payload apart from the key
   and the provenance fields (`jq` diff).
2. **Regenerates** `index.json` with `scripts/regen-index.sh` (house two-commit
   pattern: scan commit first, then regen — `last_updated` now matches the scan
   commit, so `index-freshness` CI is byte-clean). 553 entries; both names present.
3. **Leaves untouched**: `scans/JuliaPackage-Reuse-Audit.jl.json` (byte-for-byte),
   `patterns/registry.json` (its `repos_affected_list` entries are observed
   historical evidence), `outcomes/*.jsonl`, `dispatch/*.jsonl`, `repo-paths.json`
   (no entry for this repo).

### Why alias, not tombstone or regenerate

* **Tombstone / in-place rename breaks every name-join**: dashboards, time
  series, "package X changed between scan N and N+1", clade/lineage graphs, and
  the CLADE identity scheme, whose `:repo-uuid` preimage *is* the name
  (`gv-clade-index:github.com/<owner>/<name>`, profile C — see
  `standards/1-formats/deed/mappings/clade-to-repo-deed.adoc` and
  `standards/hypatia-rules/clade-identity-coherence.a2ml` HYP-S010). The
  retired name is a true historical fact: that scan really was of a repository
  called `JuliaPackage-Reuse-Audit.jl`. Renaming the file in place would cut
  this record's timeline in half.
* **Regenerate / wait for the next scan**: zero records exist under the new
  name and no scan of the renamed repo has run since the rename — waiting
  leaves name-keyed consumers resolving nothing until the next estate rescan.
* **The alias is the store's own de-facto precedent**: the earlier renames
  `JuliaKids.jl` → `JuliaForChildren.jl` and `InvestigativeJournalist.jl` →
  `InvestigativeJournalism.jl` both left their old-key scan files coexisting in
  this store; what was missing was the explicit relationship. This PR adds it,
  in the shape the estate already uses for renames: the CLADE schema's
  `[status] aliases` / `[lineage] previous-names`, per the doctrine in this
  repo's own CLADE ("a rename is NOT a phase change — the old prefixed-name
  goes to aliases[], uuid and phase are untouched") and the 2026-06-30
  `standards/0-canon/CANONICAL-NAMES.adoc` mandate (deprecated forms remain in
  "explicit migration inputs, historical records").
* **Generator not changed, generator not at risk**: scan records are written by
  `.github/workflows/ingest.yml` from the `scan_result` dispatch
  (`repo_name` = basename of the scanned repo, sent by panic-attacker's
  `scan-and-report.yml`). It will keep keying on the scanned repo's basename —
  which is now correct. The re-keyed file is a bridge: the next genuine scan of
  `JuliaPackageSpitter.jl` (next estate rescan) replaces it with fresh data and
  the timeline continues under the new key; the old key keeps the pre-rename
  history. Extra JSON fields are safe: `scripts/generate-summaries.jl` reads
  fields via `get`-with-default and the site builder reads named fields only.

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

Line-level in this repo (`grep -rI`, 2026-10-30): 30 lines retired name
(`index.json` 1, `scans/JuliaPackage-Reuse-Audit.jl.json` 1,
`scans/julia-ecosystem.json` 4, `outcomes/2026-03.jsonl` 24 — all historical
evidence, all kept); 0 lines new name before this PR.

### Acceptance

- [x] Current estate-wide occurrence counts attached, with the query used.
- [x] Chosen approach (alias vs tombstone vs regenerate) justified against the
      consumers of this store (above).
- [x] Old key still resolves (`scans/JuliaPackage-Reuse-Audit.jl.json` +
      `index.json` entry unchanged); new key present (`scans/JuliaPackageSpitter.jl.json`
      + `index.json` entry); relationship recorded (`renamed_from` /
      `renamed_at` / `rename_decision`).
- [x] No historical record rewritten or deleted (old file byte-for-byte;
      `outcomes/`, `patterns/`, `dispatch/` untouched).
- [x] The record's generator (`ingest.yml`) is what future records will use; it
      is unchanged and is what will replace the bridge record with genuine scan
      data on the next estate rescan.

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
  private — separate read grant needed to verify its gitbots' name handling;
  GitHub's rename redirect keeps the old-name URL resolving meanwhile.
