<!--
SPDX-License-Identifier: MPL-2.0
SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath)
-->

# Changelog

All notable changes to `verisimdb` will be documented in this file.

This file is generated from conventional commits by the
[`changelog-reusable.yml`](https://github.com/hyperpolymath/standards/blob/main/.github/workflows/changelog-reusable.yml)
workflow (`hyperpolymath/standards#206`). Adopt the workflow in this repo's CI to keep this file in sync automatically — see
[`templates/cliff.toml`](https://github.com/hyperpolymath/standards/blob/main/templates/cliff.toml)
for the canonical config.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
this project aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- feat(security): modernize remaining ReScript APIs in registry and playground
- feat(security): resolve 8 code-scanning alerts (Alerts 1, 3, 4, 5, 6, 7, 20, 21)

### Fixed

- fix(ci): align `ExCoveralls` floor with current `elixir-orchestration` reality (`60` → `40`); staged ramp back to `60` documented in [`elixir-orchestration/coveralls-coverage-targets.md`](elixir-orchestration/coveralls-coverage-targets.md).
- fix(licence): clear scaffold-placeholder leak (rebuilt clean) (#17)
- fix(licence): clear scaffold-placeholder leak (rebuilt clean) (#12)
- fix(ci): sync hypatia-scan.yml to canonical (kill cd-scanner build drift) (#9)
- fix(ci): build Hypatia escript from repo root (estate dogfood drift)
- fix(deps): bump vulnerable crates to patched versions (#5)

### Documentation

- docs: add faithful RUST-SPARK-STANCE.adoc (#16)
- docs: add faithful RUST-SPARK-STANCE.adoc (#11)

### CI

- ci: clear post-#35 failures (sha2/criterion adaptations) + SchemaRegistry tests (#37)
- ci: repin trufflehog off unresolvable moving-main SHA (#18)
- ci: clippy/fmt/doc/audit/deny green + 8-modality benchmarks + workflow parity (#35)
- build(deps-dev): Bump stream_data from 1.2.0 to 1.3.0 in /elixir-orchestration (#29)
- build(deps): Bump exqlite from 0.35.0 to 0.36.0 in /elixir-orchestration (#31)

## Pre-history

Prior commits to this file's introduction are recorded in git history but not formally classified into Keep-a-Changelog sections. To backfill, run `git cliff -o CHANGELOG.md` locally using the canonical [`cliff.toml`](https://github.com/hyperpolymath/standards/blob/main/templates/cliff.toml) — this is one-shot mechanical work.

---

<!-- This file was seeded by the 2026-05-26 estate tech-debt audit follow-up (Row-2 Phase 3); see [`hyperpolymath/standards/docs/audits/2026-05-26-estate-documentation-debt.md`](https://github.com/hyperpolymath/standards/blob/main/docs/audits/2026-05-26-estate-documentation-debt.md). -->
