(* SPDX-License-Identifier: MPL-2.0 *)
(* Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk> *)

(** * VeriSimDB WAL Replay — C7 Idempotence

    Mechanises the foundation-pack theorem C7 (wal_replay_idempotent)
    for the write-ahead log replay path in
    [rust-core/verisim-octad/src/store.rs::replay_wal].

    ** The original C7 spec gap (verisimdb#89)

    The audit captured in #89 found that the Rust [replay_wal] is
    NOT strictly idempotent because each replay mutates two pieces
    of metadata:

      - [version] increments by 1 (line 309 in store.rs)
      - [created_at] / [modified_at] use [Utc::now()] (line 306)

    A pure "replay twice = replay once" theorem on the entire
    [OctadStatus] struct therefore fails. Issue #89 listed three
    fix options:

      (A) reduce-then-apply with idempotent modality ops,
      (B) replay-from-snapshot,
      (C) op-level idempotence-by-construction.

    ** This module: Option A, restricted to observable state

    We prove C7 on the OBSERVABLE STATE — the entity_id → data
    mapping. Metadata fields (version counter, recovery timestamp)
    are explicitly outside the formal model; the doc comment on
    [replay_wal] in store.rs is updated to point at this restriction.

    The Rust [replay_wal] follows the [last_op_per_entity] reduction
    pattern: scan WAL entries, build a [HashMap<entity_id, last_op>],
    apply each. That reduction is exactly captured here as the
    [last_op_for] / [replay] pair. Their composition is idempotent
    by inspection.

    Declared axioms: 2 domain types ([entity_id], [data]) +
    decidable equality on [entity_id].

    Tracking: hyperpolymath/verisimdb#77 + #89.
*)

Require Import Coq.Lists.List.
Require Import Coq.Logic.FunctionalExtensionality.
Import ListNotations.

(** ** Domain *)

Parameter entity_id : Type.
Parameter data : Type.

(** Decidable equality on entity_id — true for [String] in the
    Rust source. *)
Axiom eq_entity_dec :
  forall (a b : entity_id), {a = b} + {a <> b}.

(** Observable state: a partial function from entity_id to data.
    [None] means the entity has been deleted (or never existed). *)
Definition obs_state : Type := entity_id -> option data.

(** The three observable WAL operations. [Checkpoint] in the Rust
    source is metadata-only and does not affect observable state, so
    it is intentionally omitted here. *)
Inductive wal_op : Type :=
| Upsert : entity_id -> data -> wal_op
| Delete : entity_id -> wal_op.

(** Project the entity an op affects. *)
Definition entity_of (op : wal_op) : entity_id :=
  match op with
  | Upsert e _ => e
  | Delete e => e
  end.

(** Project the post-op state for the affected entity. *)
Definition post_of (op : wal_op) : option data :=
  match op with
  | Upsert _ d => Some d
  | Delete _ => None
  end.

(** ** Last-op-per-entity reduction

    Mirrors the [entity_ops: HashMap<entity_id, (last_op, payload)>]
    loop at store.rs lines 253–273: scan entries, remember only the
    last op per entity. We model this as a fold on the list, where
    a later op overrides an earlier one for the same entity. *)
Fixpoint last_op_for (e : entity_id) (ops : list wal_op) : option wal_op :=
  match ops with
  | [] => None
  | op :: rest =>
      match last_op_for e rest with
      | Some op' => Some op'
      | None =>
          if eq_entity_dec (entity_of op) e then Some op else None
      end
  end.

(** ** Replay

    Apply the last op per entity to a starting observable state.
    Untouched entities are preserved from the prior state. *)
Definition replay (s : obs_state) (ops : list wal_op) : obs_state :=
  fun e =>
    match last_op_for e ops with
    | Some op => post_of op
    | None => s e
    end.

(** ** C7: WAL replay is idempotent

    Replaying the same WAL twice yields the same observable state as
    replaying it once.

    Proof intuition: for each entity, the "last op per entity" is the
    SAME on the second call (the WAL is unchanged), so the answer is
    determined entirely by that op and is independent of the
    intermediate state. *)
Theorem wal_replay_idempotent :
  forall (s : obs_state) (ops : list wal_op),
    replay (replay s ops) ops = replay s ops.
Proof.
  intros s ops.
  apply functional_extensionality. intros e.
  unfold replay.
  destruct (last_op_for e ops) as [op|] eqn:Hlop.
  - reflexivity.
  - reflexivity.
Qed.

(** ** Bonus: replay is deterministic

    Two starting states that agree on every entity untouched by [ops]
    produce equal post-replay states. (Stronger than idempotence:
    [replay s1 ops = replay s2 ops] whenever s1 and s2 agree off the
    set of touched entities.) *)
Theorem wal_replay_deterministic_off_touched :
  forall (s1 s2 : obs_state) (ops : list wal_op),
    (forall e, last_op_for e ops = None -> s1 e = s2 e) ->
    replay s1 ops = replay s2 ops.
Proof.
  intros s1 s2 ops Hagree.
  apply functional_extensionality. intros e.
  unfold replay.
  destruct (last_op_for e ops) as [op|] eqn:Hlop.
  - reflexivity.
  - apply Hagree. exact Hlop.
Qed.

(** ** Print Assumptions guard

    Allowed: entity_id, data, eq_entity_dec, functional_extensionality.
    The functional_extensionality axiom is a standard Coq library
    addition; it is whitelisted because it is the standard way to
    prove function equality. *)

Print Assumptions wal_replay_idempotent.
Print Assumptions wal_replay_deterministic_off_touched.
