(* SPDX-License-Identifier: MPL-2.0 *)
(* Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk> *)

(** * VeriSimDB Transaction State Machine Well-Formedness

    Mechanises the foundation-pack theorem C2
    (txn_state_machine_well_formed) for the transaction lifecycle
    defined in [rust-core/verisim-octad/src/transaction.rs].

    The Rust source declares:

      pub enum TransactionState { Active, Committed, RolledBack }

    with transitions:
      - begin    : (nothing)   -> Active
      - commit   : Active      -> Committed   (when MVCC validation passes)
      - rollback : Active      -> RolledBack

    and the invariant that Committed and RolledBack are terminal —
    any commit/rollback attempt from a terminal state returns
    TransactionError::InvalidState.

    This module proves three things:

    - [terminal_states_have_no_outgoing] — neither Committed nor
      RolledBack can transition.
    - [reachable_states_enumerable] — every reachable state is one of
      Active, Committed, RolledBack.
    - [committed_and_rolledback_distinct] — the two terminal states
      are not equal (sanity check for the inductive enumeration).

    Out-of-scope (deferred follow-ups): deadlock-detection trigger,
    MVCC version-conflict trigger, atomicity guarantee under shared
    state. See verisimdb#77 C2 sub-gaps.

    Tracking issue: hyperpolymath/verisimdb#77.
*)

Require Import Coq.Init.Logic.

(** ** Domain *)

Inductive txn_state : Type :=
| Active
| Committed
| RolledBack.

(** The two transition operations the Rust source exposes. *)
Inductive txn_op : Type :=
| OpCommit
| OpRollback.

(** Transition relation. [step s op s'] holds when applying [op] in
    state [s] yields state [s']. Mirrors the if-guarded match in
    [Transaction::commit] and [Transaction::rollback]. *)
Inductive step : txn_state -> txn_op -> txn_state -> Prop :=
| step_commit   : step Active OpCommit Committed
| step_rollback : step Active OpRollback RolledBack.

(** ** C2.a: terminal states have no outgoing transitions *)

Theorem terminal_states_have_no_outgoing :
  forall (op : txn_op) (s' : txn_state),
    ~ step Committed op s' /\ ~ step RolledBack op s'.
Proof.
  intros op s'. split.
  - intros H. inversion H.
  - intros H. inversion H.
Qed.

(** Reachability from genesis: a state is reachable iff it equals
    [Active] (after [begin]) or there is a [step] from another
    reachable state. *)
Inductive reachable : txn_state -> Prop :=
| reach_begin : reachable Active
| reach_step  : forall s op s',
    reachable s -> step s op s' -> reachable s'.

(** ** C2.b: every reachable state is one of the three declared states *)

Theorem reachable_states_enumerable :
  forall s, reachable s -> s = Active \/ s = Committed \/ s = RolledBack.
Proof.
  intros s Hr.
  induction Hr as [|s op s' Hs IH Hstep].
  - left. reflexivity.
  - inversion Hstep; subst.
    + right. left. reflexivity.
    + right. right. reflexivity.
Qed.

(** ** C2.c: Committed and RolledBack are distinct terminal states *)

Theorem committed_and_rolledback_distinct :
  Committed <> RolledBack.
Proof.
  intros H. discriminate H.
Qed.

(** ** Print Assumptions guard *)

Print Assumptions terminal_states_have_no_outgoing.
Print Assumptions reachable_states_enumerable.
Print Assumptions committed_and_rolledback_distinct.
