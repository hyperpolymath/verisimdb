// SPDX-License-Identifier: MPL-2.0
//! Property-based tests for the optimizer — the Rust image of `formal/Planner.v`.
//!
//! `Planner.v` proves `optimize_is_permutation` about a *Coq* function. That
//! says nothing about this crate until something checks the Rust against the
//! same statement, and `Planner.v:23-28` has promised exactly that since the
//! module was written:
//!
//! > A property test added alongside Provenance.v's chain-link integrity check
//! > would exercise this in Rust.
//!
//! It was never added. This file is that test, and closes the refinement link
//! #113 owes.
//!
//! Worth being precise about the gap it closes. `optimizer.rs` already has
//! eight unit tests, but they assert *ordering* (`test_vector_before_graph`,
//! `test_semantic_always_last`) and *counts*. None of them asserts the
//! multiset — which is the actual content of the permutation property, and the
//! one thing that would catch a node being silently dropped or duplicated.
//!
//! The Coq model abstracts a node as `(modality, list condition)`. These
//! properties are stated over that same projection so the two are comparable,
//! with the caveats the Coq header records:
//!
//!   * Coq's `optimize` is total; the Rust one is partial (`EmptyPlan`), so the
//!     generators produce non-empty plans and emptiness is checked separately.
//!   * Coq's cost carrier is `nat`; the Rust tie-breaker is `f64` compared with
//!     `partial_cmp(...).unwrap_or(Equal)`, which is why `prop_optimize_never_panics`
//!     exists at all.

use std::collections::BTreeMap;

use proptest::prelude::*;
use verisim_planner::plan::{ConditionKind, LogicalPlan, PlanNode, QuerySource};
use verisim_planner::{Modality, Planner, PlannerConfig};

// ---------------------------------------------------------------------------
// Generators
// ---------------------------------------------------------------------------

fn modality_strategy() -> impl Strategy<Value = Modality> {
    prop_oneof![
        Just(Modality::Graph),
        Just(Modality::Vector),
        Just(Modality::Tensor),
        Just(Modality::Semantic),
        Just(Modality::Document),
        Just(Modality::Temporal),
        Just(Modality::Provenance),
        Just(Modality::Spatial),
    ]
}

/// Covers all nine `ConditionKind` constructors. The planner treats conditions
/// opaquely when reordering, but they participate in cost estimation, so a
/// generator that only emitted one variant would exercise a single cost path.
fn condition_strategy() -> impl Strategy<Value = ConditionKind> {
    prop_oneof![
        ("[a-z]{1,8}", "[a-z0-9]{1,8}")
            .prop_map(|(field, value)| ConditionKind::Equality { field, value }),
        ("[a-z]{1,8}", "[0-9]{1,4}", "[0-9]{1,4}")
            .prop_map(|(field, low, high)| ConditionKind::Range { field, low, high }),
        "[a-z ]{1,12}".prop_map(|query| ConditionKind::Fulltext { query }),
        (1usize..500).prop_map(|k| ConditionKind::Similarity { k }),
        ("[a-z_]{1,10}", proptest::option::of(1u32..8))
            .prop_map(|(predicate, depth)| ConditionKind::Traversal { predicate, depth }),
        "[0-9]{4}".prop_map(|timestamp| ConditionKind::AtTime { timestamp }),
        "[a-z]{1,8}".prop_map(|contract| ConditionKind::ProofVerification { contract }),
        "[a-z]{1,8}".prop_map(|operation| ConditionKind::TensorOp { operation }),
        "[a-z ]{1,10}".prop_map(|expression| ConditionKind::Predicate { expression }),
    ]
}

fn node_strategy() -> impl Strategy<Value = PlanNode> {
    (
        modality_strategy(),
        prop::collection::vec(condition_strategy(), 0..4),
        prop::collection::vec("[a-z]{1,6}", 0..3),
        proptest::option::of(1usize..2000),
    )
        .prop_map(
            |(modality, conditions, projections, early_limit)| PlanNode {
                modality,
                conditions,
                projections,
                early_limit,
            },
        )
}

/// Non-empty by construction: `Planner::optimize` returns `EmptyPlan` for an
/// empty node list, so an empty plan is a different property (asserted once,
/// below) rather than a case these should silently skip.
fn plan_strategy() -> impl Strategy<Value = LogicalPlan> {
    prop::collection::vec(node_strategy(), 1..12).prop_map(|nodes| LogicalPlan {
        source: QuerySource::Octad,
        nodes,
        post_processing: vec![],
    })
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// The Coq node projection `(modality, list condition)`, as a countable key.
///
/// Conditions are rendered with `{:?}` because that is precisely what
/// `optimizer.rs` does when it builds `pushed_predicates` — so this compares
/// the two sides on the representation the code actually produces, rather than
/// on one invented for the test.
fn multiset(pairs: impl Iterator<Item = (Modality, String)>) -> BTreeMap<(String, String), usize> {
    let mut m = BTreeMap::new();
    for (modality, conds) in pairs {
        *m.entry((format!("{modality:?}"), conds)).or_insert(0) += 1;
    }
    m
}

fn logical_multiset(plan: &LogicalPlan) -> BTreeMap<(String, String), usize> {
    multiset(plan.nodes.iter().map(|n| {
        let conds: Vec<String> = n.conditions.iter().map(|c| format!("{c:?}")).collect();
        (n.modality, conds.join("|"))
    }))
}

fn physical_multiset(plan: &verisim_planner::PhysicalPlan) -> BTreeMap<(String, String), usize> {
    multiset(
        plan.steps
            .iter()
            .map(|s| (s.modality, s.pushed_predicates.join("|"))),
    )
}

fn planner() -> Planner {
    Planner::new(PlannerConfig::default())
}

// ---------------------------------------------------------------------------
// Properties
// ---------------------------------------------------------------------------

proptest! {
    /// The Rust image of `Planner.v`'s `optimize_is_permutation`.
    ///
    /// Nodes may be reordered; none may be added, dropped or duplicated. This
    /// is the multiset equality that the existing ordering/count unit tests do
    /// not cover — a swap of two nodes for each other would satisfy a count
    /// assertion and fail this one.
    #[test]
    fn prop_optimize_is_permutation(plan in plan_strategy()) {
        let physical = planner().optimize(&plan).expect("non-empty plan optimizes");

        prop_assert_eq!(
            plan.nodes.len(),
            physical.steps.len(),
            "node count changed"
        );
        prop_assert_eq!(
            logical_multiset(&plan),
            physical_multiset(&physical),
            "the multiset of (modality, conditions) was not preserved"
        );
    }

    /// Reordering must not change what the plan is estimated to cost.
    ///
    /// This is the cost-invariance side of the same story: `optimize` is only a
    /// legitimate optimisation if permuting the input leaves the total estimate
    /// alone. Asserted with a relative tolerance rather than `==` because f64
    /// `+` and `*` are commutative but **not associative**, so `combine` is
    /// permutation-invariant only up to rounding — the same caveat recorded in
    /// `Planner.v`'s header.
    #[test]
    fn prop_optimize_total_cost_invariant(
        plan in plan_strategy(),
        rotation in 0usize..12,
    ) {
        let p = planner();
        let base = p.optimize(&plan).expect("optimizes");

        let mut rotated_nodes = plan.nodes.clone();
        let n = rotated_nodes.len();
        rotated_nodes.rotate_left(rotation % n);
        let rotated = LogicalPlan {
            source: plan.source.clone(),
            nodes: rotated_nodes,
            post_processing: plan.post_processing.clone(),
        };
        let other = p.optimize(&rotated).expect("optimizes");

        let (a, b) = (base.total_cost.time_ms, other.total_cost.time_ms);
        let tolerance = 1e-9_f64.max(a.abs().max(b.abs()) * 1e-9);
        prop_assert!(
            (a - b).abs() <= tolerance,
            "total cost changed under permutation: {a} vs {b}"
        );
    }

    /// The optimizer must not panic on any well-formed plan.
    ///
    /// Specifically guards the comparator. `optimizer.rs` ties on
    /// `a.time_ms.partial_cmp(&b.time_ms).unwrap_or(Ordering::Equal)`, and a NaN
    /// makes that non-transitive — which violates `sort_by`'s documented
    /// contract and may panic outright on Rust >= 1.81. NaN is believed
    /// unreachable today (the only division in `CostModel::estimate` is guarded
    /// and feeds `selectivity`, not `time_ms`), but nothing in the types
    /// enforces it, so the belief is worth testing rather than asserting.
    #[test]
    fn prop_optimize_never_panics(plan in plan_strategy()) {
        let physical = planner().optimize(&plan).expect("optimizes");
        for step in &physical.steps {
            prop_assert!(
                !step.cost.time_ms.is_nan(),
                "NaN reached a step's time_ms; the sort comparator is unsound for this input"
            );
        }
        prop_assert!(!physical.total_cost.time_ms.is_nan(), "NaN total cost");
    }

    /// Pushdown fields survive optimization for every generated node.
    ///
    /// The unit test added with the fix covers one hand-built plan; this covers
    /// the generated space. Both matter: dropping these was not merely lossy,
    /// because `CostModel::estimate` already discounts a node carrying an
    /// `early_limit`, so the plan was priced for a pushdown the executor could
    /// not perform.
    #[test]
    fn prop_pushdown_fields_survive(plan in plan_strategy()) {
        let physical = planner().optimize(&plan).expect("optimizes");

        let mut want: Vec<(String, Vec<String>, Option<usize>)> = plan
            .nodes
            .iter()
            .map(|n| (format!("{:?}", n.modality), n.projections.clone(), n.early_limit))
            .collect();
        let mut got: Vec<(String, Vec<String>, Option<usize>)> = physical
            .steps
            .iter()
            .map(|s| (format!("{:?}", s.modality), s.projections.clone(), s.early_limit))
            .collect();

        want.sort();
        got.sort();
        prop_assert_eq!(want, got, "projection/early-limit pushdown did not survive");
    }
}

/// `optimize` is partial where the Coq model is total: the empty plan is an
/// error, not an empty result. Stated once here so the generators above can
/// stay non-empty without that difference going unrecorded.
#[test]
fn empty_plan_is_rejected() {
    let empty = LogicalPlan {
        source: QuerySource::Octad,
        nodes: vec![],
        post_processing: vec![],
    };
    assert!(
        planner().optimize(&empty).is_err(),
        "empty plan must be rejected, not silently optimized to an empty plan"
    );
}
