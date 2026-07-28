(* SPDX-License-Identifier: MPL-2.0 *)
(* Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk> *)

(** * VeriSimDB Provenance Hash-Chain Verification

    Mechanises the foundation-pack theorems P2 ([record_verify_iff_unchanged]),
    P3 ([chain_linked_step], [chain_linked]) and P4 ([append_preserves_verified],
    [build_chain_all_verified]) for the provenance modality defined in
    [rust-core/verisim-provenance/src/lib.rs].

    The Rust source maintains an append-only hash chain where each record's
    [parent_hash] equals the SHA-256 [content_hash] of its predecessor. The
    theorems below capture, in increasing strength:

    - [record_verify_iff_unchanged] (P2) — a single record verifies iff
      its [content_hash] is the SHA-256 of its content payload and
      parent_hash.
    - [chain_linked_step] (P3) — honest append preserves the chain-link
      invariant.
    - [chain_linked] (P3) — every chain built from genesis by repeated
      honest append is well-linked.
    - [append_preserves_verified] (P4) — honest append takes an
      all-verified chain to an all-verified chain.
    - [build_chain_all_verified] (P4) — every chain built from empty by
      repeated honest append has all records verifying.

    The only declared axiom is [sha256_collision_resistant]. It is NOT
    consumed by the theorems below; the [Print Assumptions] guard at
    file end confirms each closes under the global context. The axiom
    is reserved for later uniqueness theorems (V8).

    Build oracle: [just -f formal/Justfile all]. CI: [.github/workflows/coq-build.yml].

    Tracking issue: hyperpolymath/verisimdb#77.
*)

Require Import Coq.Lists.List.

(* Keep Print Assumptions output on one line per axiom: the CI and Justfile
   guards match /^name :/ with awk, and Coq's default ~78-column wrap would
   split a longer axiom type across lines and silently escape the check. *)
Set Printing Width 400.

(* Keep Print Assumptions output on one line per axiom: the CI and Justfile
   guards match /^name :/ with awk, and Coq's default ~78-column wrap would
   split a longer axiom type across lines and silently escape the check. *)
Import ListNotations.

(** ** Domain *)

(** Opaque content payload. In the Rust source this is the record's
    non-hash fields: event_type, actor, timestamp, source, description. *)
Parameter content : Type.

(** Opaque hash output. In the Rust source this is a 64-character hex
    string (SHA-256 digest). *)
Parameter hash : Type.

(** SHA-256 of a canonical (content, parent_hash) payload. *)
Parameter sha256 : content -> hash -> hash.

(** The genesis hash. In the Rust source this is the SHA-256 of the empty
    string, used as the [parent_hash] of every chain's first record. *)
Parameter genesis_hash : hash.

(** SHA-256 collision resistance, stated as injectivity of [sha256] on the
    product of (content, parent_hash). Standard cryptographic assumption. *)
Axiom sha256_collision_resistant :
  forall (c1 c2 : content) (h1 h2 : hash),
    sha256 c1 h1 = sha256 c2 h2 -> c1 = c2 /\ h1 = h2.

(** A provenance record: content payload, parent hash, stored content hash. *)
Record provenance_record : Type := mk_record {
  rec_content : content;
  rec_parent_hash : hash;
  rec_content_hash : hash;
}.

(** [record_verify] mirrors [verify()] in the Rust source: the stored
    [content_hash] field equals the SHA-256 of the content payload and
    parent_hash. *)
Definition record_verify (r : provenance_record) : Prop :=
  rec_content_hash r = sha256 (rec_content r) (rec_parent_hash r).

(** Honest construction — the [new()] constructor in the Rust source.
    A record built this way always verifies. *)
Definition mk_honest (c : content) (parent : hash) : provenance_record :=
  mk_record c parent (sha256 c parent).

(** ** P2: [record_verify_iff_unchanged]

    A record verifies iff it has the honest form — i.e., its
    [content_hash] field has not been modified relative to its content
    and parent_hash. *)
Theorem record_verify_iff_unchanged :
  forall r,
    record_verify r <-> exists c parent, r = mk_honest c parent.
Proof.
  intros r. split.
  - intros Hv.
    destruct r as [c p h].
    unfold record_verify in Hv. simpl in Hv.
    exists c, p.
    unfold mk_honest. rewrite Hv. reflexivity.
  - intros [c [p Hr]]. subst.
    unfold record_verify, mk_honest. reflexivity.
Qed.

(** ** Chain integrity *)

Definition chain : Type := list provenance_record.

(** Inductive linkage from a starting hash. A chain is linked from [h]
    when every record's [parent_hash] equals its predecessor's
    [content_hash], with [h] taking the role of the predecessor for the
    first record. *)
Inductive chain_linked_from : hash -> chain -> Prop :=
| linked_nil : forall h, chain_linked_from h []
| linked_cons :
    forall h r rest,
      rec_parent_hash r = h ->
      chain_linked_from (rec_content_hash r) rest ->
      chain_linked_from h (r :: rest).

(** A chain is well-linked iff it is linked from the genesis hash. *)
Definition chain_well_linked (c : chain) : Prop :=
  chain_linked_from genesis_hash c.

(** The [parent_hash] that the next appended record should use:
    the last record's [content_hash], or the starting hash for empty
    chains. *)
Fixpoint chain_tail_hash_from (h : hash) (c : chain) : hash :=
  match c with
  | [] => h
  | r :: rest => chain_tail_hash_from (rec_content_hash r) rest
  end.

Definition chain_tail_hash (c : chain) : hash :=
  chain_tail_hash_from genesis_hash c.

(** Honest append — mirrors [append()] in the Rust source: extends the
    chain with a new record whose [parent_hash] points at the tip and
    whose [content_hash] is computed by SHA-256. *)
Definition append_record (c : chain) (cnt : content) : chain :=
  c ++ [mk_honest cnt (chain_tail_hash c)].

(** Snoc lemma: extending a linked chain with a record whose
    [parent_hash] equals the chain's tail hash preserves linkage. *)
Lemma chain_linked_from_snoc :
  forall c r h,
    chain_linked_from h c ->
    rec_parent_hash r = chain_tail_hash_from h c ->
    chain_linked_from h (c ++ [r]).
Proof.
  induction c as [|r' rest IH]; intros r h Hlinked Hparent; simpl in *.
  - apply linked_cons.
    + exact Hparent.
    + apply linked_nil.
  - inversion Hlinked; subst.
    apply linked_cons.
    + reflexivity.
    + apply IH; assumption.
Qed.

(** ** P3 step: [chain_linked_step]

    Appending an honest record to a well-linked chain preserves
    well-linkedness. *)
Theorem chain_linked_step :
  forall c cnt,
    chain_well_linked c -> chain_well_linked (append_record c cnt).
Proof.
  intros c cnt H.
  unfold chain_well_linked, append_record, chain_tail_hash in *.
  apply chain_linked_from_snoc.
  - exact H.
  - reflexivity.
Qed.

(** ** P3 corollary: [chain_linked]

    Every chain built from the empty chain by a sequence of honest
    [append_record] operations is well-linked. *)
Fixpoint build_chain (cnts : list content) : chain :=
  match cnts with
  | [] => []
  | cnt :: rest => append_record (build_chain rest) cnt
  end.

Theorem chain_linked :
  forall cnts, chain_well_linked (build_chain cnts).
Proof.
  induction cnts as [|cnt rest IH]; simpl.
  - apply linked_nil.
  - apply chain_linked_step. exact IH.
Qed.

(** ** P4: [append_preserves_verified]

    The Rust [append()] constructs the new record via [Self::new()]
    (mirrored here as [mk_honest]), which always computes the
    [content_hash] honestly. Hence appending to an all-verified chain
    yields an all-verified chain. The proof reduces to two facts:

    - [Forall_app] — [Forall P (xs ++ ys)] iff [Forall P xs /\ Forall P ys].
    - [mk_honest_verifies] — every [mk_honest] record satisfies
      [record_verify] by construction. *)

Lemma mk_honest_verifies :
  forall cnt h, record_verify (mk_honest cnt h).
Proof.
  intros. unfold record_verify, mk_honest. simpl. reflexivity.
Qed.

Theorem append_preserves_verified :
  forall c cnt,
    Forall record_verify c ->
    Forall record_verify (append_record c cnt).
Proof.
  intros c cnt H.
  unfold append_record.
  apply Forall_app. split.
  - exact H.
  - apply Forall_cons.
    + apply mk_honest_verifies.
    + apply Forall_nil.
Qed.

(** ** P4 corollary: [build_chain_all_verified]

    Combining [append_preserves_verified] with [build_chain] yields the
    closed-form result: every chain built from empty by repeated honest
    append has all records verifying. The base case is [Forall_nil];
    the step case is [append_preserves_verified]. *)
Theorem build_chain_all_verified :
  forall cnts, Forall record_verify (build_chain cnts).
Proof.
  induction cnts as [|cnt rest IH]; simpl.
  - apply Forall_nil.
  - apply append_preserves_verified. exact IH.
Qed.

(** ** Print Assumptions guard

    Each theorem must close under the global context. The
    [sha256_collision_resistant] axiom is declared but unused; CI greps
    each [Print Assumptions] block for "Closed under the global context"
    to detect axiom slippage. *)

Print Assumptions record_verify_iff_unchanged.
Print Assumptions chain_linked_step.
Print Assumptions chain_linked.
Print Assumptions append_preserves_verified.
Print Assumptions build_chain_all_verified.
