// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//!
//! VeriSimDB NIF Bridge — Erlang/Elixir native interface for direct in-process calls.
//!
//! ## Status: SCAFFOLD — no operation is implemented yet
//!
//! This crate exposes the *shape* of the in-process transport (a Rustler NIF
//! surface parallel to the HTTP API) but **no operation is wired to the
//! store**. Every function returns `{:error, :not_implemented}`.
//!
//! This is deliberate and load-bearing: an earlier version returned canned
//! success JSON (e.g. `delete_octad` replied `{"status":"deleted"}` having
//! deleted nothing). With `VERISIM_TRANSPORT=nif` or `auto` selecting the NIF,
//! that turned a write into *silent data loss reported as success*. An
//! unimplemented operation MUST fail loudly, never fake success — so the
//! honest stub is the correct behaviour until the store is actually wired in.
//!
//! When an operation is implemented, replace its `not_implemented` body with a
//! real call through the shared [`runtime`]/store; the Elixir transport then
//! observes a real result instead of an error and begins routing to the NIF.
//!
//! ## Transport selection (Elixir side)
//!
//! ```text
//! VERISIM_TRANSPORT=http   # Default: HTTP to verisim-api server
//! VERISIM_TRANSPORT=nif    # Demand NIF: surfaces {:error, :not_implemented} loudly
//! VERISIM_TRANSPORT=auto   # NIF only if OPERATIONAL, else HTTP — today always HTTP
//! ```

#![forbid(unsafe_code)]
use rustler::Atom;
use std::sync::OnceLock;
use tokio::runtime::Runtime;

mod atoms {
    rustler::atoms! {
        error,
        not_implemented,
    }
}

/// The honest verdict every operation returns until it is wired to the store:
/// the Elixir term `{:error, :not_implemented}`. Identical in shape to the
/// pure-Elixir fallback stub's `{:error, :nif_not_loaded}`, so a loaded-but-
/// unimplemented NIF and an absent NIF are indistinguishable to callers — both
/// non-operational, neither ever fabricating success.
#[inline]
fn not_implemented() -> (Atom, Atom) {
    (atoms::error(), atoms::not_implemented())
}

/// Shared Tokio runtime for executing async store operations from synchronous
/// NIF entry points. Initialised on first use.
///
/// Unused until the first operation is wired to the store (it will drive the
/// store's async API from these synchronous NIF bodies).
#[allow(dead_code)]
static RUNTIME: OnceLock<Runtime> = OnceLock::new();

/// Get or create the shared Tokio runtime.
#[allow(dead_code)]
fn runtime() -> &'static Runtime {
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(4)
            .enable_all()
            .build()
            .expect("failed to create Tokio runtime for NIF bridge")
    })
}

// ---------------------------------------------------------------------------
// NIF functions — all not-yet-implemented; each fails loudly, never fakes.
// ---------------------------------------------------------------------------

/// Create a new octad entity from a JSON string. NOT IMPLEMENTED.
#[rustler::nif(schedule = "DirtyCpu")]
fn create_octad(_json_input: String) -> (Atom, Atom) {
    not_implemented()
}

/// Retrieve a octad by ID. NOT IMPLEMENTED.
#[rustler::nif(schedule = "DirtyCpu")]
fn get_octad(_octad_id: String) -> (Atom, Atom) {
    not_implemented()
}

/// Delete a octad entity by ID. NOT IMPLEMENTED.
///
/// Previously returned `{"status":"deleted"}` without deleting anything — the
/// silent-data-loss bug this stub exists to prevent.
#[rustler::nif(schedule = "DirtyCpu")]
fn delete_octad(_octad_id: String) -> (Atom, Atom) {
    not_implemented()
}

/// Full-text search across the document modality. NOT IMPLEMENTED.
#[rustler::nif(schedule = "DirtyCpu")]
fn search_text(_query: String, _limit: usize) -> (Atom, Atom) {
    not_implemented()
}

/// Vector similarity search. NOT IMPLEMENTED.
#[rustler::nif(schedule = "DirtyCpu")]
fn search_vector(_embedding_json: String, _k: usize) -> (Atom, Atom) {
    not_implemented()
}

/// Paginated listing of octad entities. NOT IMPLEMENTED.
#[rustler::nif(schedule = "DirtyCpu")]
fn list_octads(_limit: usize, _offset: usize) -> (Atom, Atom) {
    not_implemented()
}

/// Get drift detection scores for a specific entity. NOT IMPLEMENTED.
///
/// Previously returned all-zero scores, indistinguishable from a real
/// "no drift" measurement — a false negative for the engine's core claim.
#[rustler::nif(schedule = "DirtyCpu")]
fn get_drift_score(_octad_id: String) -> (Atom, Atom) {
    not_implemented()
}

/// Trigger normalisation (self-repair) for a drifted entity. NOT IMPLEMENTED.
#[rustler::nif(schedule = "DirtyCpu")]
fn trigger_normalise(_octad_id: String) -> (Atom, Atom) {
    not_implemented()
}

// ---------------------------------------------------------------------------
// NIF registration
// ---------------------------------------------------------------------------

rustler::init!("Elixir.VeriSim.NifBridge");
