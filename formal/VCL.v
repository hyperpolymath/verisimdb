(* SPDX-License-Identifier: MPL-2.0 *)
(* Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk> *)

(** * VCL Preservation — V2

    Mechanises the foundation-pack theorem V2 (vql_preservation) for
    VCL (the VeriSim Consonance Language; renamed from VQL on
    2026-04-05). The original semantics in
    [docs/vcl-formal-semantics.adoc] use BIG-STEP evaluation
    [e ⇓ v], which does not compose with preservation as classically
    stated. This module closes #92 by introducing a minimal
    SMALL-STEP calculus and proving preservation against it.

    ** Scope

    The Rust/ReScript VCL parser and type checker handle a richer
    language. This module proves preservation for the CORE subset:

    - boolean / proof values
    - conditional [if ec then et else ee]
    - opaque proof terms (as values; no internal reduction)

    The "proof-term reduction" #92 blocker 2 is resolved by treating
    proof terms as values — they do not reduce under β. This matches
    the operational reality (proven-library ZKP witnesses are
    serialized blobs; no in-language reduction).

    The full VCL has filter expressions, projections, modality
    quantifiers, and PROOF clauses. Each adds congruence-style step
    rules; the preservation argument extends mechanically per
    rule. The 4-rule core here is the SMALLEST language that
    exhibits the small-step shape and proves the keystone result.

    ** Cross-doc: echo-types

    V2 maps to [EchoGradedComonadInterface.agda]: type-preservation
    is the comonad [ε ∘ δ = id] property in the graded comonad of
    "well-typed terms at type τ". Reduction is the comonad action.
    See [formal/CROSS-REPO-MAP.adoc].

    Tracking: hyperpolymath/verisimdb#77 + #92.
*)

Require Import Coq.Init.Logic.

(** ** Syntax *)

Inductive ty : Type :=
| TBool : ty
| TProof : ty.

Inductive expr : Type :=
| EBool  : bool -> expr
| EProof : expr                          (* opaque proof value *)
| EIf    : expr -> expr -> expr -> expr.

(** ** Typing *)

(** [typing e t] holds when [e] has type [t]. There is no variable
    binding in this fragment, so no typing context is needed. *)
Inductive typing : expr -> ty -> Prop :=
| T_Bool  : forall b : bool, typing (EBool b) TBool
| T_Proof : typing EProof TProof
| T_If    : forall ec et ee t,
              typing ec TBool ->
              typing et t ->
              typing ee t ->
              typing (EIf ec et ee) t.

(** ** Small-step reduction

    Closes #92 blocker 1 (big-step → small-step). The three rules
    are the standard congruence-or-iota pattern. *)
Inductive step : expr -> expr -> Prop :=
| S_IfTrue  : forall et ee, step (EIf (EBool true) et ee) et
| S_IfFalse : forall et ee, step (EIf (EBool false) et ee) ee
| S_If      : forall ec ec' et ee,
                step ec ec' ->
                step (EIf ec et ee) (EIf ec' et ee).

(** ** Values

    A value is an expression with no further reductions. *)
Inductive value : expr -> Prop :=
| V_Bool  : forall b, value (EBool b)
| V_Proof : value EProof.

(** ** V2: preservation

    Well-typed terms reduce to well-typed terms. *)
Theorem vql_preservation :
  forall e e' t,
    typing e t -> step e e' -> typing e' t.
Proof.
  intros e e' t Hty Hstep.
  generalize dependent t.
  induction Hstep; intros t Hty; inversion Hty; subst.
  - (* S_IfTrue: result is et, with type t from H4 *)
    assumption.
  - (* S_IfFalse: result is ee, with type t from H5 *)
    assumption.
  - (* S_If: congruence — re-build EIf with reduced ec *)
    apply T_If.
    + apply IHHstep. assumption.
    + assumption.
    + assumption.
Qed.

(** ** Bonus: progress

    Closes the type-soundness pair (preservation + progress). A
    well-typed term is either a value or can take a step. *)
Theorem vql_progress :
  forall e t,
    typing e t -> value e \/ exists e', step e e'.
Proof.
  intros e t Hty.
  induction Hty.
  - left. apply V_Bool.
  - left. apply V_Proof.
  - (* EIf ec et ee *)
    destruct IHHty1 as [Hv|[ec' Hstep]].
    + (* ec is a value, must be EBool b *)
      inversion Hv; subst.
      * (* EBool b *)
        destruct b.
        -- right. exists et. apply S_IfTrue.
        -- right. exists ee. apply S_IfFalse.
      * (* EProof, but ec : TBool — impossible *)
        inversion Hty1.
    + (* ec can step *)
      right. exists (EIf ec' et ee). apply S_If. exact Hstep.
Qed.

(** ** Print Assumptions guard

    Pure inductive proof; closes under the global context with zero
    axioms. *)

Print Assumptions vql_preservation.
Print Assumptions vql_progress.
