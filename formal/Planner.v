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

    [optimize_is_permutation] was an [Axiom] until 2026-07-28. It is now a
    [Theorem]. The change matters because, as an axiom over a [Parameter]
    [optimize], it was not merely unproven — it was *unprovable*: nothing
    constrained [optimize], so [fun _ => []] inhabited the parameter and
    refuted the statement. Assuming it was therefore assuming the conclusion.

    The discharge replaces the parameter with a definition, which is what
    makes the statement provable at all:

      - [modality] becomes an [Inductive] mirroring [crate::Modality]'s eight
        constructors, with [execution_priority] transcribing the Rust match
        arms exactly (verisim-planner/src/lib.rs).
      - [optimize] becomes [Mergesort]'s [sort] over a decidable total order
        on nodes: execution priority first, cost as tie-breaker — the same
        key [Optimizer::optimize]'s [sort_by] comparator uses.
      - The permutation property is then discharged by the standard library's
        [Permuted_sort], which is itself closed under the global context.

    Two [Parameter]s remain by design, and being parametric in them makes the
    result stronger rather than weaker — the theorem holds for *any* condition
    representation and *any* cost function:

      - [condition] : the Rust [ConditionKind] has nine constructors carrying
        [String]/[usize] payloads; none of that is relevant to a permutation.
      - [node_cost] : abstracts [CostModel::estimate]'s [time_ms]. Modelling
        the real cost model would constrain the theorem to one cost function
        for no gain.

    Two honest gaps between this model and the Rust, neither affecting the
    permutation property, both worth stating rather than eliding:

      - [node_cost] returns [nat]; the Rust tie-breaker is [f64] compared with
        [partial_cmp(...).unwrap_or(Equal)]. A NaN would make that comparator
        non-transitive and break [sort_by]'s contract. NaN is unreachable today
        (the only division in [CostModel::estimate] is guarded and feeds
        [selectivity], not [time_ms]) but nothing in the Rust types enforces it.
      - The Rust [optimize] is partial — it returns [PlannerError::EmptyPlan]
        for an empty plan — whereas [sort []] is [[]]. Total here, partial there.

    Full Q1 (semantic equivalence) remains MODERATE and open; [exec_node_comm]
    in PlannerSemantic.v is a genuine spec axiom needing per-operator semantics,
    not something this change touches.

    Tracking issue: hyperpolymath/verisimdb#77.
*)

Require Import Coq.Lists.List.
Require Import Coq.Sorting.Permutation.
Require Import Coq.Sorting.Mergesort.
Require Import Coq.Structures.Orders.
Require Import Coq.Arith.PeanoNat.
Require Import Lia.

(* Keep Print Assumptions output on one line per axiom: the CI and Justfile
   guards match /^name :/ with awk, and Coq's default ~78-column wrap would
   split a longer axiom type across lines and silently escape the check. *)
Set Printing Width 400.

Import ListNotations.

(** ** Domain *)

(** [modality] mirrors [crate::Modality] (verisim-planner/src/lib.rs).

    All eight octad constructors are represented so the proof model and Rust
    planner share the same scheduling domain. *)
Inductive modality : Type :=
  | Graph
  | Vector
  | Tensor
  | Semantic
  | Document
  | Temporal
  | Provenance
  | Spatial.

(** Transcribes [Modality::execution_priority] arm for arm. Lower runs
    earlier: Temporal first (often cached), Vector/Spatial/Document next (selective
    indexes), Provenance chain walks after indexed lookups, Graph middle,
    Tensor moderate, Semantic last (ZKP expensive). *)
Definition execution_priority (m : modality) : nat :=
  match m with
  | Temporal => 10
  | Vector   => 20
  | Spatial  => 25
  | Document => 30
  | Provenance => 35
  | Graph    => 40
  | Tensor   => 50
  | Semantic => 90
  end.

(** Conditions stay opaque. [crate::plan::ConditionKind] has nine constructors
    (Equality, Range, Fulltext, Similarity, Traversal, AtTime,
    ProofVerification, TensorOp, Predicate), none of whose structure bears on
    whether the optimizer reorders or loses nodes. *)
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

(** ** Optimizer

    [CostModel::estimate]'s [time_ms], abstracted. See the header for why this
    stays a [Parameter] and what the [nat]-vs-[f64] gap is. *)
Parameter node_cost : node -> nat.

(** The comparator from [Optimizer::optimize]'s [sort_by]: execution priority
    first, total cost as tie-breaker. *)
Definition node_leb (a b : node) : bool :=
  if Nat.ltb (execution_priority (fst a)) (execution_priority (fst b)) then true
  else if Nat.ltb (execution_priority (fst b)) (execution_priority (fst a)) then false
  else Nat.leb (node_cost a) (node_cost b).

(** Totality — the property [f64] with [unwrap_or(Equal)] cannot guarantee, and
    the reason the cost carrier is [nat] here. *)
Lemma node_leb_total : forall a b, node_leb a b = true \/ node_leb b a = true.
Proof.
  intros a b. unfold node_leb.
  destruct (Nat.ltb (execution_priority (fst a)) (execution_priority (fst b))) eqn:Hab.
  - left; reflexivity.
  - destruct (Nat.ltb (execution_priority (fst b)) (execution_priority (fst a))) eqn:Hba.
    + right; reflexivity.
    + apply Nat.ltb_ge in Hab. apply Nat.ltb_ge in Hba.
      destruct (Nat.leb_spec (node_cost a) (node_cost b)) as [H|H].
      * left; reflexivity.
      * right. apply Nat.leb_le. lia.
Qed.

Module PlanOrder <: TotalLeBool.
  Definition t := node.
  Definition leb := node_leb.
  Infix "<=?" := leb (at level 70, no associativity).
  Theorem leb_total : forall a1 a2, leb a1 a2 = true \/ leb a2 a1 = true.
  Proof. exact node_leb_total. Qed.
End PlanOrder.

Module PlanSort := Sort PlanOrder.

(** The optimizer: a stable mergesort under [node_leb]. *)
Definition optimize (lp : logical_plan) : physical_plan := PlanSort.sort lp.

(** The former axiom, now discharged from [Permuted_sort]. *)
Theorem optimize_is_permutation :
  forall lp, Permutation lp (optimize lp).
Proof.
  intro lp. apply PlanSort.Permuted_sort.
Qed.

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
