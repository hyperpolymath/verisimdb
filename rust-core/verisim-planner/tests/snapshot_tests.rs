// SPDX-License-Identifier: MPL-2.0
//! Snapshot tests for verisim-planner.
//!
//! The planner's ExplainOutput shape (steps, costs, hints, strategy,
//! text rendering) is part of its public contract — any change is
//! visible to users via EXPLAIN.  Snapshot tests detect silent shape
//! drift: a regression in step ordering, cost calculation, or hint
//! generation will fail loudly with a clear diff.
//!
//! The cost numbers themselves are deterministic given a fixed
//! PlannerConfig, so we can snapshot them directly without redaction.
//! If non-determinism creeps in (timestamps, RNG, etc.) add
//! `[redactions]` filters to settings.
//!
//! Workflow when snapshots fail:
//!   1. Inspect the diff with `cargo insta review`
//!   2. Accept legitimate changes or fix the regression
//!   3. Commit the updated `tests/snapshots/*.snap` file
//!
//! In CI, snapshots are read-only: any drift fails the build.

use insta::{assert_yaml_snapshot, with_settings};
use verisim_planner::config::PlannerConfig;
use verisim_planner::optimizer::Planner;
use verisim_planner::plan::{ConditionKind, LogicalPlan, PlanNode, QuerySource};
use verisim_planner::Modality;

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

fn document_search_plan() -> LogicalPlan {
    LogicalPlan {
        source: QuerySource::Octad,
        nodes: vec![PlanNode {
            modality: Modality::Document,
            conditions: vec![ConditionKind::Fulltext {
                query: "machine learning".to_string(),
            }],
            projections: vec![],
            early_limit: Some(10),
        }],
        post_processing: vec![],
    }
}

fn graph_then_vector_plan() -> LogicalPlan {
    LogicalPlan {
        source: QuerySource::Octad,
        nodes: vec![
            PlanNode {
                modality: Modality::Graph,
                conditions: vec![ConditionKind::Traversal {
                    predicate: "relates_to".to_string(),
                    depth: Some(2),
                }],
                projections: vec![],
                early_limit: None,
            },
            PlanNode {
                modality: Modality::Vector,
                conditions: vec![ConditionKind::Similarity { k: 10 }],
                projections: vec![],
                early_limit: None,
            },
        ],
        post_processing: vec![],
    }
}

fn semantic_proof_plan() -> LogicalPlan {
    LogicalPlan {
        source: QuerySource::Octad,
        nodes: vec![
            PlanNode {
                modality: Modality::Document,
                conditions: vec![ConditionKind::Fulltext {
                    query: "audit".to_string(),
                }],
                projections: vec![],
                early_limit: None,
            },
            PlanNode {
                modality: Modality::Semantic,
                conditions: vec![ConditionKind::ProofVerification {
                    contract: "integrity-v1".to_string(),
                }],
                projections: vec![],
                early_limit: None,
            },
        ],
        post_processing: vec![],
    }
}

// ---------------------------------------------------------------------------
// Snapshot tests
// ---------------------------------------------------------------------------

#[test]
fn snapshot_document_search_plan() {
    let planner = Planner::new(PlannerConfig::default());
    let explain = planner.explain(&document_search_plan()).unwrap();

    with_settings!({ description => "Single-modality document search (LIMIT 10)" }, {
        assert_yaml_snapshot!("document_search_plan", explain);
    });
}

#[test]
fn snapshot_graph_then_vector_plan() {
    let planner = Planner::new(PlannerConfig::default());
    let explain = planner.explain(&graph_then_vector_plan()).unwrap();

    with_settings!({ description => "Two-modality graph + vector; expect parallel strategy with vector first" }, {
        assert_yaml_snapshot!("graph_then_vector_plan", explain);
    });
}

#[test]
fn snapshot_semantic_proof_plan() {
    let planner = Planner::new(PlannerConfig::default());
    let explain = planner.explain(&semantic_proof_plan()).unwrap();

    with_settings!({ description => "Document + semantic proof; semantic always last" }, {
        assert_yaml_snapshot!("semantic_proof_plan", explain);
    });
}

#[test]
fn snapshot_total_cost_is_deterministic() {
    // Same plan through the same config must always yield the same cost.
    // This is the "no hidden state" property — if it ever fails, the
    // planner has acquired a non-deterministic dependency.
    let planner = Planner::new(PlannerConfig::default());
    let a = planner.explain(&graph_then_vector_plan()).unwrap();
    let b = planner.explain(&graph_then_vector_plan()).unwrap();

    assert_eq!(a.total_cost_ms, b.total_cost_ms);
    assert_eq!(a.strategy, b.strategy);
    assert_eq!(a.steps.len(), b.steps.len());
    for (s1, s2) in a.steps.iter().zip(b.steps.iter()) {
        assert_eq!(s1.step, s2.step);
        assert_eq!(s1.operation, s2.operation);
        assert_eq!(s1.estimated_cost_ms, s2.estimated_cost_ms);
    }
}
