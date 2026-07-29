;; SPDX-License-Identifier: MPL-2.0
;; SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
;;
;; Guix development manifest for VeriSimDB.
;;
;;     guix shell -m guix.scm
;;
;; SCOPE — read this before extending the file.
;;
;; This is a *development environment* manifest, not a package definition. It
;; replaces the `flake.nix` dev shell removed in the same change, one-for-one:
;; that file declared a toolchain, not a build, and said so in its own header.
;; Nothing that existed before is lost by this swap.
;;
;; It is deliberately NOT a `(package ...)` with `cargo-build-system`. VeriSimDB
;; is a 17-crate Rust workspace plus an Elixir/OTP layer; a correct
;; `#:cargo-inputs` enumeration would need every transitive crate pinned, and a
;; definition that merely *looks* like a package build while failing to produce
;; one would be worse than this honest manifest — the estate already has enough
;; artefacts that satisfy a presence check without doing anything. Promote this
;; to a real package definition when someone can build and verify it end to end.
;;
;; NOT VALIDATED LOCALLY: Guix is not installed on the authoring machine, so
;; this file has not been evaluated. Run `guix shell -m guix.scm -- true` before
;; relying on it, and fix rather than delete it if a specification name has
;; drifted.
;;
;; Toolchain rationale — each entry maps to something this repo actually uses:
;;
;;   rust, rust:cargo   17-crate workspace under rust-core/ (Cargo.toml)
;;   rust:rustfmt       `cargo fmt` is enforced in CI
;;   elixir, erlang     elixir-orchestration/ (mix, 647 tests)
;;   coq                formal/ — 9 modules, gated by coq-build.yml
;;   just               formal/Justfile and the root justfile
;;   reuse              REUSE compliance is a required check (776/776)
;;   git, gnu-make      assumed by several recipes
;;
;; Deliberately absent: Node, npm, Deno and friends. This repo's own
;; NPM/Bun Blocker and TypeScript/JavaScript Blocker workflows reject them, and
;; a template-supplied toolchain that installed them is exactly the class of
;; drift those gates exist to catch.

(specifications->manifest
 (list "rust"
       "rust:cargo"
       "rust:rustfmt"
       "elixir"
       "erlang"
       "coq"
       "just"
       "reuse"
       "git"
       "gnu-make"))
