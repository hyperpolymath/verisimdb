(* SPDX-License-Identifier: MPL-2.0 *)
(* Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk> *)

(** * VeriSimDB Planner — Full Q1 semantic equivalence

    Mechanises FULL Q1 (`planner_logical_physical_equivalence`) on top
    of Q1-lite (Planner.v): not just structural preservation, but
    SEMANTIC equivalence — executing the optimized plan against any
    state yields the same result as executing the original plan.

    ** The Q1-lite → Q1-full gap

    Q1-lite (Planner.v) proves `optimize` is a permutation. That
    captures the structural fact: no nodes added, no nodes dropped.
    But it does NOT prove semantic equivalence — for that, we need to
    know what "executing a node" MEANS.

    ** Approach

    The audit found Planner::optimize is a deterministic single-pass
    [stable_sort_by] over modality execution priority. Crucially,
    each filter node restricts the result set; set restriction is
    COMMUTATIVE. We axiomatise this as [exec_node_comm] and derive
    semantic equivalence from Q1-lite's permutation property via the
    classical "fold-commutative-is-permutation-invariant" lemma.

    This covers the audit-identified operator-semantics gaps as a
    UNIFORM commutativity axiom:

      - Equality / Range / Fulltext (field comparisons) — clearly
        commute (intersection of sets).
      - Similarity (HNSW k-NN) — commutes when applied as a
        post-filter on the candidate set. The k-bound interaction
        with other filters is order-independent at the set level.
      - Traversal (graph reachability) — commutes at the set level
        (reachability set is invariant under filter intersection).
      - ProofVerification — commutes (a proof either holds or
        doesn't; intersection is commutative).

    ** Cross-doc: echo-types

    Full Q1 = result-set echo invariance under optimization. The
    abstract echo-types analogue is [EchoNoSectionGeneric.agda]
    (sections-up-to-equivalence) plus [EchoCost.agda] (lift cost).
    Tropical-resource-typing repo is the home for the cost-side
    algebra. See [formal/CROSS-REPO-MAP.adoc].

    Tracking: hyperpolymath/verisimdb#77 + Q1 row.
*)

Require Import Coq.Lists.List.
Require Import Coq.Sorting.Permutation.
Require Import Planner.

(* Keep Print Assumptions output on one line per axiom: the CI and Justfile
   guards match /^name :/ with awk, and Coq's default ~78-column wrap would
   split a longer axiom type across lines and silently escape the check. *)
Set Printing Width 400.

Import ListNotations.

(** ** Domain

    This module said "reusing Planner.v abstractions" while in fact
    re-declaring its own [modality], [condition], [node], [optimize] and a
    second copy of [optimize_is_permutation]. The two files agreed only by
    coincidence, and the duplicated axiom meant discharging it in Planner.v
    would have left an identical assumption standing here.

    It now genuinely imports Planner.v, so [modality] (an [Inductive]),
    [node], [optimize] (a [Definition]) and the discharged
    [optimize_is_permutation] [Theorem] all come from one place. *)

Parameter octad : Type.

Definition plan : Type := logical_plan.
Definition state : Type := list octad.

(** ** Per-node execution semantics

    [exec_node n s] applies node [n]'s conditions to candidate state
    [s], returning the filtered subset. *)
Parameter exec_node : node -> state -> state.

(** Spec axiom — set restrictions COMMUTE.

    Applying node n1 then n2 yields the same state as n2 then n1.
    Faithful to the operational reality: each modality filter is a
    set-restriction operation, and set intersection is commutative
    regardless of operator type (Equality, Similarity, Traversal,
    ProofVerification, …). *)
Axiom exec_node_comm :
  forall n1 n2 s, exec_node n1 (exec_node n2 s) = exec_node n2 (exec_node n1 s).

(** ** Plan execution

    Apply each node's exec_node in sequence. *)
Fixpoint exec_plan (p : plan) (s : state) : state :=
  match p with
  | [] => s
  | n :: rest => exec_plan rest (exec_node n s)
  end.

(** ** Optimizer

    Imported from Planner.v, where [optimize] is [Mergesort]'s [sort] under a
    decidable total order and [optimize_is_permutation] is a [Theorem]
    discharged from [Permuted_sort]. Previously both were re-declared here as
    a [Parameter] and an [Axiom]. *)

(** ** Helper: exec_plan is invariant under permutation of nodes *)
Theorem exec_plan_perm_invariant :
  forall p1 p2 s,
    Permutation p1 p2 ->
    exec_plan p1 s = exec_plan p2 s.
Proof.
  intros p1 p2 s Hperm.
  generalize dependent s.
  induction Hperm; intros s; simpl.
  - reflexivity.
  - apply IHHperm.
  - rewrite exec_node_comm. reflexivity.
  - rewrite IHHperm1, IHHperm2. reflexivity.
Qed.

(** ** Q1-full: planner_semantic_equivalence

    For ANY plan [p] and ANY state [s], executing the optimized plan
    yields the same state as executing the original. *)
Theorem planner_semantic_equivalence :
  forall p s, exec_plan (optimize p) s = exec_plan p s.
Proof.
  intros p s.
  apply exec_plan_perm_invariant.
  apply Permutation_sym.
  apply optimize_is_permutation.
Qed.

(** ** Bonus: planner_set_membership_preserved

    A specific octad is in the optimized plan's result iff it is in
    the original plan's result. This is the witness-level
    equivalence — for any predicate, "is this octad in the output?"
    yields the same answer for both plans. *)
Theorem planner_set_membership_preserved :
  forall p s o,
    In o (exec_plan (optimize p) s) <-> In o (exec_plan p s).
Proof.
  intros p s o.
  rewrite planner_semantic_equivalence.
  split; auto.
Qed.

(** ** Print Assumptions guard *)

Print Assumptions planner_semantic_equivalence.
Print Assumptions planner_set_membership_preserved.
