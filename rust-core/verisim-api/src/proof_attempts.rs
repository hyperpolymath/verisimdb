// SPDX-License-Identifier: MPL-2.0
//! Proof-attempt row store + the S4 learning-loop HTTP surface.
//!
//! ECHIDNA's dispatcher (`echidna/src/rust/verisim_bridge.rs`) writes one row
//! per prover dispatch exit and reads two query shapes back:
//!
//! ```text
//! POST /api/v1/proof_attempts                              record one attempt
//! GET  /api/v1/proof_attempts?obligation_id={h}&limit={n}  attempts for a goal,
//!                                                          most recent first
//! GET  /api/v1/mv_prover_success_by_class?class={c}        per-prover success
//!                                                          aggregate for a class
//! ```
//!
//! The aggregate endpoint keeps its ClickHouse-era name (`mv_…`) because the
//! client contract is the path string, not the storage engine; here the
//! "materialised view" is computed on demand over the row store. Hypatia's H3
//! proof-strategy rule reads the same endpoint, closing the loop:
//! attempt → row → aggregate → strategy recommendation → next attempt.
//!
//! Storage: in-memory `Vec` behind an `RwLock`, with optional JSONL
//! persistence (one row per line, append-on-record, loaded at startup) when
//! the server runs with a persistence directory. Aggregations scan the rows;
//! at the write rates of a proof dispatcher (hundreds of rows per CI run)
//! this stays far below any threshold where an indexed engine would matter.

use std::collections::HashMap;
use std::fs::OpenOptions;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::sync::RwLock;

use axum::extract::{Query, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde::{Deserialize, Serialize};
use tracing::{info, warn};

use crate::AppState;

/// A single proof attempt, exactly mirroring the JSON body ECHIDNA posts.
/// Field names are snake_case; prover/outcome are lowercase strings
/// ("coq", "lean", …, "success", "timeout", "failure", "unknown").
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ProofAttempt {
    /// UUID v4 unique to this attempt.
    pub attempt_id: String,
    /// Stable hash of (repo, file, claim) — groups retries of one obligation.
    pub obligation_id: String,
    /// Repository identifier, e.g. "hyperpolymath/echidna".
    pub repo: String,
    /// File path within the repo.
    pub file: String,
    /// Human-readable obligation text.
    pub claim: String,
    /// Obligation class for strategy lookup, e.g. "linearity", "termination".
    pub obligation_class: String,
    /// Prover used ("coq", "lean", "z3", …).
    pub prover_used: String,
    /// Outcome ("success", "timeout", "failure", "unknown").
    pub outcome: String,
    pub duration_ms: u64,
    /// Confidence score in [0.0, 1.0].
    pub confidence: f32,
    /// Prior attempt on the same obligation (for retries).
    pub parent_attempt_id: Option<String>,
    /// Strategy used, e.g. "portfolio", "gnn-guided", "manual", "retry".
    pub strategy_tag: String,
    /// ISO-8601 UTC timestamp when the attempt started.
    pub started_at: String,
    /// ISO-8601 UTC timestamp when the attempt completed.
    pub completed_at: String,
    /// Truncated prover stdout/stderr.
    pub prover_output: String,
    /// Error message if outcome != success.
    pub error_message: Option<String>,
}

/// One row of the per-class aggregate. Matches the shape
/// `[{"prover": "z3", "success_rate": 0.85, "total_attempts": 42}, …]`
/// that `verisim_bridge::query_prover_success_by_class` deserialises.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProverSuccessRow {
    pub prover: String,
    pub success_rate: f32,
    pub total_attempts: u32,
}

/// Row store for proof attempts: in-memory with optional JSONL persistence.
pub struct ProofAttemptStore {
    rows: RwLock<Vec<ProofAttempt>>,
    persist_path: Option<PathBuf>,
}

impl ProofAttemptStore {
    /// Purely in-memory store (default build).
    pub fn in_memory() -> Self {
        Self {
            rows: RwLock::new(Vec::new()),
            persist_path: None,
        }
    }

    /// Store backed by `<dir>/proof_attempts.jsonl`. Existing rows are
    /// loaded at startup; malformed lines are skipped with a warning so one
    /// bad write can never brick the loop.
    pub fn with_persistence(dir: impl AsRef<Path>) -> std::io::Result<Self> {
        let dir = dir.as_ref();
        std::fs::create_dir_all(dir)?;
        let path = dir.join("proof_attempts.jsonl");

        let mut rows = Vec::new();
        if path.exists() {
            let file = std::fs::File::open(&path)?;
            for (idx, line) in BufReader::new(file).lines().enumerate() {
                let line = line?;
                if line.trim().is_empty() {
                    continue;
                }
                match serde_json::from_str::<ProofAttempt>(&line) {
                    Ok(attempt) => rows.push(attempt),
                    Err(e) => warn!(
                        line = idx + 1,
                        error = %e,
                        "skipping malformed proof_attempts.jsonl row"
                    ),
                }
            }
            info!(
                count = rows.len(),
                path = %path.display(),
                "loaded persisted proof attempts"
            );
        }

        Ok(Self {
            rows: RwLock::new(rows),
            persist_path: Some(path),
        })
    }

    /// Validate and record one attempt. Returns the attempt_id.
    ///
    /// Validation is deliberately minimal — the loop must keep closing even
    /// for provers/outcomes this build has never heard of. Non-finite
    /// confidence is rejected; out-of-range confidence is clamped to [0, 1].
    pub fn record(&self, mut attempt: ProofAttempt) -> Result<String, String> {
        for (field, value) in [
            ("attempt_id", &attempt.attempt_id),
            ("obligation_id", &attempt.obligation_id),
            ("prover_used", &attempt.prover_used),
            ("outcome", &attempt.outcome),
        ] {
            if value.trim().is_empty() {
                return Err(format!("{field} must be non-empty"));
            }
        }
        if !attempt.confidence.is_finite() {
            return Err("confidence must be a finite number".to_string());
        }
        attempt.confidence = attempt.confidence.clamp(0.0, 1.0);

        if let Some(path) = &self.persist_path {
            let line = serde_json::to_string(&attempt).map_err(|e| e.to_string())?;
            let mut file = OpenOptions::new()
                .create(true)
                .append(true)
                .open(path)
                .map_err(|e| format!("open {}: {e}", path.display()))?;
            writeln!(file, "{line}").map_err(|e| format!("append {}: {e}", path.display()))?;
        }

        let id = attempt.attempt_id.clone();
        self.rows
            .write()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .push(attempt);
        Ok(id)
    }

    /// All attempts for one obligation, most recent first, capped at `limit`.
    pub fn by_obligation(&self, obligation_id: &str, limit: usize) -> Vec<ProofAttempt> {
        let rows = self
            .rows
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        rows.iter()
            .rev()
            .filter(|a| a.obligation_id == obligation_id)
            .take(limit)
            .cloned()
            .collect()
    }

    /// Per-prover success aggregate for one obligation class, sorted by
    /// prover name for deterministic output.
    pub fn success_by_class(&self, obligation_class: &str) -> Vec<ProverSuccessRow> {
        let rows = self
            .rows
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let mut counts: HashMap<String, (u32, u32)> = HashMap::new();
        for attempt in rows.iter().filter(|a| a.obligation_class == obligation_class) {
            let entry = counts.entry(attempt.prover_used.clone()).or_insert((0, 0));
            entry.1 += 1;
            if attempt.outcome == "success" {
                entry.0 += 1;
            }
        }
        let mut out: Vec<ProverSuccessRow> = counts
            .into_iter()
            .map(|(prover, (successes, total))| ProverSuccessRow {
                prover,
                success_rate: successes as f32 / total as f32,
                total_attempts: total,
            })
            .collect();
        out.sort_by(|a, b| a.prover.cmp(&b.prover));
        out
    }

    /// Number of stored attempts.
    pub fn len(&self) -> usize {
        self.rows
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .len()
    }

    /// Whether the store is empty.
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

// ── HTTP handlers ────────────────────────────────────────────────────────

fn error_json(status: StatusCode, message: impl Into<String>) -> Response {
    (
        status,
        Json(serde_json::json!({ "error": message.into() })),
    )
        .into_response()
}

/// `POST /proof_attempts` — record one attempt, 201 + `{"attempt_id": …}`.
pub async fn record_handler(
    State(state): State<AppState>,
    Json(attempt): Json<ProofAttempt>,
) -> Response {
    match state.proof_attempts.record(attempt) {
        Ok(attempt_id) => (
            StatusCode::CREATED,
            Json(serde_json::json!({ "attempt_id": attempt_id })),
        )
            .into_response(),
        Err(message) => error_json(StatusCode::BAD_REQUEST, message),
    }
}

#[derive(Deserialize)]
pub struct ListParams {
    obligation_id: Option<String>,
    limit: Option<usize>,
}

/// Hard cap on `limit` so a missing/huge value cannot dump the whole table.
const MAX_LIST_LIMIT: usize = 500;

/// `GET /proof_attempts?obligation_id={h}&limit={n}` — JSON array, most
/// recent first. An unknown obligation_id yields `[]` (200, not 404).
pub async fn list_handler(
    State(state): State<AppState>,
    Query(params): Query<ListParams>,
) -> Response {
    let Some(obligation_id) = params.obligation_id else {
        return error_json(
            StatusCode::BAD_REQUEST,
            "query parameter 'obligation_id' is required",
        );
    };
    let limit = params.limit.unwrap_or(50).min(MAX_LIST_LIMIT);
    Json(state.proof_attempts.by_obligation(&obligation_id, limit)).into_response()
}

#[derive(Deserialize)]
pub struct ClassParams {
    class: Option<String>,
}

/// `GET /mv_prover_success_by_class?class={c}` — JSON array of
/// `ProverSuccessRow`. A class with no attempts yields `[]` (200, not 404).
pub async fn success_by_class_handler(
    State(state): State<AppState>,
    Query(params): Query<ClassParams>,
) -> Response {
    let Some(class) = params.class else {
        return error_json(
            StatusCode::BAD_REQUEST,
            "query parameter 'class' is required",
        );
    };
    Json(state.proof_attempts.success_by_class(&class)).into_response()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn attempt(obligation_id: &str, class: &str, prover: &str, outcome: &str) -> ProofAttempt {
        ProofAttempt {
            attempt_id: format!("id-{obligation_id}-{prover}-{outcome}-{}", rand_suffix()),
            obligation_id: obligation_id.to_string(),
            repo: "hyperpolymath/echidna".to_string(),
            file: "proofs/test.v".to_string(),
            claim: "true".to_string(),
            obligation_class: class.to_string(),
            prover_used: prover.to_string(),
            outcome: outcome.to_string(),
            duration_ms: 1,
            confidence: if outcome == "success" { 1.0 } else { 0.0 },
            parent_attempt_id: None,
            strategy_tag: "test".to_string(),
            started_at: "2026-06-11T00:00:00Z".to_string(),
            completed_at: "2026-06-11T00:00:01Z".to_string(),
            prover_output: String::new(),
            error_message: None,
        }
    }

    fn rand_suffix() -> u64 {
        use std::sync::atomic::{AtomicU64, Ordering};
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        COUNTER.fetch_add(1, Ordering::Relaxed)
    }

    #[test]
    fn record_then_read_back_most_recent_first() {
        let store = ProofAttemptStore::in_memory();
        let first = attempt("goal-1", "c", "z3", "failure");
        let second = attempt("goal-1", "c", "z3", "success");
        store.record(first.clone()).unwrap();
        store.record(second.clone()).unwrap();
        store.record(attempt("goal-2", "c", "z3", "success")).unwrap();

        let rows = store.by_obligation("goal-1", 50);
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].attempt_id, second.attempt_id, "most recent first");
        assert_eq!(rows[1].attempt_id, first.attempt_id);
        assert!(store.by_obligation("goal-absent", 50).is_empty());
    }

    #[test]
    fn limit_caps_results() {
        let store = ProofAttemptStore::in_memory();
        for _ in 0..10 {
            store.record(attempt("goal-cap", "c", "z3", "success")).unwrap();
        }
        assert_eq!(store.by_obligation("goal-cap", 3).len(), 3);
    }

    #[test]
    fn success_rate_aggregation() {
        let store = ProofAttemptStore::in_memory();
        store.record(attempt("g1", "linearity", "z3", "success")).unwrap();
        store.record(attempt("g2", "linearity", "z3", "success")).unwrap();
        store.record(attempt("g3", "linearity", "z3", "failure")).unwrap();
        store.record(attempt("g4", "linearity", "coq", "timeout")).unwrap();
        store.record(attempt("g5", "termination", "coq", "success")).unwrap();

        let rows = store.success_by_class("linearity");
        assert_eq!(rows.len(), 2);
        // Sorted by prover name: coq before z3.
        assert_eq!(rows[0].prover, "coq");
        assert_eq!(rows[0].total_attempts, 1);
        assert_eq!(rows[0].success_rate, 0.0);
        assert_eq!(rows[1].prover, "z3");
        assert_eq!(rows[1].total_attempts, 3);
        assert!((rows[1].success_rate - 2.0 / 3.0).abs() < f32::EPSILON);
        assert!(rows
            .iter()
            .all(|r| (0.0..=1.0).contains(&r.success_rate)));
        assert!(store.success_by_class("no-such-class").is_empty());
    }

    #[test]
    fn validation_rejects_empty_fields_and_bad_confidence() {
        let store = ProofAttemptStore::in_memory();

        let mut a = attempt("g", "c", "z3", "success");
        a.attempt_id = "  ".to_string();
        assert!(store.record(a).is_err());

        let mut b = attempt("g", "c", "z3", "success");
        b.confidence = f32::NAN;
        assert!(store.record(b).is_err());

        let mut c = attempt("g", "c", "z3", "success");
        c.confidence = 7.5;
        store.record(c).unwrap();
        assert_eq!(store.by_obligation("g", 1)[0].confidence, 1.0, "clamped");
    }

    #[test]
    fn persistence_round_trip() {
        let dir = std::env::temp_dir().join(format!(
            "verisim-proof-attempts-test-{}-{}",
            std::process::id(),
            rand_suffix()
        ));

        {
            let store = ProofAttemptStore::with_persistence(&dir).unwrap();
            store.record(attempt("g-persist", "c", "lean", "success")).unwrap();
            store.record(attempt("g-persist", "c", "lean", "failure")).unwrap();
        }

        // Reopen: rows must come back in insertion order.
        let reopened = ProofAttemptStore::with_persistence(&dir).unwrap();
        assert_eq!(reopened.len(), 2);
        let rows = reopened.by_obligation("g-persist", 50);
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].outcome, "failure", "most recent first survives reload");

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn persistence_skips_malformed_lines() {
        let dir = std::env::temp_dir().join(format!(
            "verisim-proof-attempts-malformed-{}-{}",
            std::process::id(),
            rand_suffix()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("proof_attempts.jsonl");
        let good = serde_json::to_string(&attempt("g-ok", "c", "z3", "success")).unwrap();
        std::fs::write(&path, format!("{good}\nnot json at all\n")).unwrap();

        let store = ProofAttemptStore::with_persistence(&dir).unwrap();
        assert_eq!(store.len(), 1, "good row loaded, bad row skipped");

        std::fs::remove_dir_all(&dir).ok();
    }
}
