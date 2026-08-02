#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# SessionStart hook — Claude Code on the web (cloud sessions).
#
# Cloud sessions ship cargo but NOT Erlang/Elixir, which VeriSimDB's
# orchestration layer (elixir-orchestration) needs. This hook installs
# Erlang+Elixir, warms the Rust workspace, and best-effort prefetches the
# Elixir deps, so a cloud session starts ready to build and test.
#
# Cloud-only: a no-op on local checkouts (your machine already has the
# toolchain). Every step is best-effort — a blocked registry or network
# must never abort session startup.
#
# Network note: `mix deps.get` needs outbound access to the Hex registry
# (repo.hex.pm / builds.hex.pm). On a restrictive "Trusted" network
# allowlist those are blocked (HTTP 403) and skipped cleanly; on "Full"
# network access they complete. The cargo path works on Trusted (crates.io
# is allowlisted). For faster, cached startup, the install step is better
# moved to the environment's Setup Script (snapshotted once) — see
# https://code.claude.com/docs/en/claude-code-on-the-web
set -uo pipefail

[ "${CLAUDE_CODE_REMOTE:-}" != "true" ] && exit 0

ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
cd "$ROOT" || exit 0

LOG="${TMPDIR:-/tmp}/verisimdb-session-start.log"
: >"$LOG"
log() { echo "[verisimdb] $*"; }
run() { "$@" >>"$LOG" 2>&1; } # best-effort: failures land in the log, never abort

# ── Install Erlang + Elixir (idempotent: skip when already present) ────
# Cloud images omit BEAM. Erlang/OTP 25 from apt + a precompiled Elixir
# 1.17 (built for OTP 25) from GitHub satisfies elixir-orchestration's
# `elixir: "~> 1.17"` requirement.
if ! command -v mix >/dev/null 2>&1; then
  log "installing Erlang (apt, OTP 25) + Elixir 1.17 (GitHub)…"
  run apt-get update -qq
  run apt-get install -y -qq erlang-nox
  z="${TMPDIR:-/tmp}/elixir.zip"
  if run curl -fsSL -o "$z" \
      https://github.com/elixir-lang/elixir/releases/download/v1.17.3/elixir-otp-25.zip; then
    run mkdir -p /usr/local/elixir && run unzip -o "$z" -d /usr/local/elixir
    for b in elixir elixirc mix iex; do
      [ -f "/usr/local/elixir/bin/$b" ] && run ln -sf "/usr/local/elixir/bin/$b" /usr/local/bin/
    done
  fi
fi

# ── Warm the Rust workspace (works on Trusted; the core of VeriSimDB) ──
# `cargo fetch` downloads the whole workspace's dependency tree so later
# `cargo build` / `cargo test` are offline-capable. A full `cargo build`
# is deliberately NOT run — the ~20-crate workspace is heavy and this hook
# is synchronous; it compiles on first use instead.
log "fetching Rust workspace dependencies (cargo fetch)…"
run cargo fetch --locked || run cargo fetch

# ── Best-effort: Elixir orchestration deps (needs Hex; 403 on Trusted) ─
if command -v mix >/dev/null 2>&1 && [ -f elixir-orchestration/mix.exs ]; then
  log "fetching Elixir deps (best-effort; needs Hex registry access)…"
  (
    cd elixir-orchestration || exit 0
    run mix local.hex --force
    run mix local.rebar --force
    run mix deps.get
  )
fi

log "ready (full log: $LOG)."
exit 0
