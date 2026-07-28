(* SPDX-License-Identifier: MPL-2.0 *)
(* Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk> *)

(** * VeriSimDB Planner — Logical/Physical Plan Equivalence (Q1-lite)

    Mechanises Q1 [planner_logical_physical_equivalence] for the query
    planner in [rust-core/verisim-planner/src/optimizer.rs].

    Audit finding (verisimdb#77, recorded in PR #90 description): the
    optimizer is a deterministic single-pass [stable_sort_by] over the
    logical plan nodes, ordered by [Modality::execution_priority] with
    cost as a tie-breaker. Nodes are mapped 1:1 to physical steps;
    [conditions] are preserved verbatim as [pushed_predicates].

    Full Q1 (semantic equivalence: same input data yields same result
    set under logical vs physical) is MODERATE — blocked on
    formalising the semantics of [Similarity] (HNSW k-NN),
    [Traversal] (graph reachability), and [ProofVerification]. See
    verisimdb#77 Q1 row. This module proves the STRUCTURAL preservation
    direction: optimize is a permutation. Semantic equivalence then
    follows once per-operator semantics are formalised.

    Declared axiom: [optimize_is_permutation]. This is a structural
    contract on the Rust optimizer enforced by inspection of
    [Planner::optimize] (no node insertion, no node deletion, only
    reordering via [Vec::sort_by]). A property test added alongside
    Provenance.v's chain-link integrity check would exercise this in
    Rust.

    Tracking issue: hyperpolymath/verisimdb#77.
*)

Require Import Coq.Lists.List.
Require Import Coq.Sorting.Permutation.

(* Keep Print Assumptions output on one line per axiom: the CI and Justfile
   guards match /^name :/ with awk, and Coq's default ~78-column wrap would
   split a longer axiom type across lines and silently escape the check. *)
Set Printing Width 400.

(* Keep Print Assumptions output on one line per axiom: the CI and Justfile
   guards match /^name :/ with awk, and Coq's default ~78-column wrap would
   split a longer axiom type across lines and silently escape the check. *)
Import ListNotations.

(** ** Domain *)

(** Opaque modality and condition types. Mirrors [crate::Modality]
    and [crate::plan::Condition] in the Rust source. *)
Parameter modality : Type.
Parameter condition : Type.

(** A plan node is a (modality, condition list) pair. *)
Definition node : Type := (modality * list condition)%type.

(** A logical plan is a list of nodes. *)
Definition logical_plan : Type := list node.

(** A physical plan, at this layer of abstraction, has the same
    shape — each step records its modality and the conditions it
    pushes down. The Rust [PhysicalPlan.steps] enriches each step
    with cost and an optimization hint; those are orthogonal to the
    structural-preservation property below. *)
Definition physical_plan : Type := list node.

(** ** Optimizer contract

    The optimizer is a permutation: it reorders the input nodes but
    neither adds nor drops any. *)
Parameter optimize : logical_plan -> physical_plan.

Axiom optimize_is_permutation :
  forall lp, Permutation lp (optimize lp).

(** ** Q1-lite corollaries *)

(** Q1-lite (a): the optimizer preserves node count. *)
Theorem planner_preserves_node_count :
  forall lp, length lp = length (optimize lp).
Proof.
  intros lp. apply Permutation_length. apply optimize_is_permutation.
Qed.

(** Q1-lite (b): every node in the logical plan appears in the
    physical plan, and vice versa. *)
Theorem planner_preserves_membership :
  forall lp (n : node),
    In n lp <-> In n (optimize lp).
Proof.
  intros lp n. split.
  - intros H. eapply Permutation_in.
    + apply optimize_is_permutation.
    + exact H.
  - intros H. eapply Permutation_in.
    + apply Permutation_sym. apply optimize_is_permutation.
    + exact H.
Qed.

(** Q1-lite (c): the multiset of nodes is preserved. This is the
    strongest structural property short of pointwise equivalence —
    same nodes, possibly reordered. *)
Theorem planner_preserves_multiset :
  forall lp, Permutation lp (optimize lp).
Proof.
  intros lp. apply optimize_is_permutation.
Qed.

(** ** Print Assumptions guard

    Allowed axioms/parameters: modality, condition, optimize,
    optimize_is_permutation. Anything else fails the CI guard. *)

Print Assumptions planner_preserves_node_count.
Print Assumptions planner_preserves_membership.
Print Assumptions planner_preserves_multiset.
