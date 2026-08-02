(* SPDX-License-Identifier: MPL-2.0 *)
(* Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk> *)

(** * VeriSimDB Octad Modality Algebra (O-series + R1-R3)

    Mechanises the OCTAD DATA MODEL and its MODALITY ALGEBRA as written
    (on paper) in [docs/papers/arcvix-octad-data-model.tex], section
    [sec:octad] "The Octad Data Model":

    - [def:modset]     Modality Set        — the fixed eight-element basis.
    - [def:octad]      Octad               — (id, phi), phi : M -> Sigma_m u {bot}.
    - [inv:persist]    Identity Persistence — id is immutable under mutation.
    - [def:projection] Projection  pi_M.
    - [def:merge]      Merge       (+)      with conflict resolver [resolve].
    - Proposition      Merge Commutativity  (the paper's one proven claim).
    - [def:enrichment] Enrichment  enrich_m — the fundamental write primitive.

    ** Why this module exists

    The paper's "Modality Algebra" subsection [sec:modality-algebra] is
    the octad-modularity experiment. Its sole stated proof — the
    Proposition "Merge Commutativity" — is a one-line pen-and-paper
    argument ("follows directly from the symmetry of the case analysis in
    [def:merge] and the commutativity assumption on resolve").
    [merge_commutative] below is that proposition MECHANISED. The
    associativity and idempotence companions ([merge_associative],
    [merge_idempotent]) close the conditional CRDT-shape laws R1-R3 from
    the verisimdb#77 inventory.

    ** On verisimdb#77's "honest uncertainty" about R1-R3

    Issue #77 flags R1/R2/R3 ("CRDT-shaped octad merge") as "likely false
    as currently written", because the concrete AutoMerge heuristic in
    [verisim-normalizer/src/conflict.rs] is not unconditionally
    commutative. The honest resolution, mechanised here, is the paper's:
    the octad merge (+) inherits EXACTLY the algebra of its
    conflict-resolution kernel [resolve]. (+) is commutative / associative
    / idempotent precisely WHEN [resolve] is. The laws are therefore
    stated as implications from [resolve]'s properties — the faithful
    form. A CRDT-shaped [resolve] (e.g. a join on a semilattice)
    instantiates all three; AutoMerge does not, and the implication makes
    that explicit rather than over-claiming.

    ** Faithfulness to the Rust source

    The eight-constructor [modality] enumeration mirrors the eight boolean
    fields of [ModalityStatus] in [rust-core/verisim-octad/src/lib.rs]
    (graph, vector, tensor, semantic, document, temporal, provenance,
    spatial). [is_complete] / [missing] mirror [ModalityStatus::is_complete]
    and [ModalityStatus::missing]; [complete_iff_no_missing] is the
    cross-method consistency check between those two independent Rust
    functions (edit one without the other and this theorem breaks).
    [resolve] abstracts [RegenerationStrategy] in
    [rust-core/verisim-normalizer/src/regeneration.rs].

    The [def:enrichment] clause "every enrichment appends a record to
    phi'(P) and phi'(R)" (the audit-trail invariant) is the hash-chain
    append modelled separately in [formal/Provenance.v]
    ([append_preserves_verified]); it is intentionally NOT re-modelled
    here. This module proves the structural part of enrichment: it sets
    the target modality and leaves the others untouched.

    ** Abstraction note

    Per-modality value spaces Sigma_m are unified into one opaque [mval]
    (the algebra laws are parametric in the value type, exactly as
    [Drift.v] abstracts the score type). The dependently-typed layout
    phi : forall m, Sigma_m u {bot} specialises this by a sigma-type;
    that refinement is orthogonal to the algebraic laws proved here.

    ** Cross-doc: echo-types

    Projection pi_M is a TRUNCATION of the modality section phi — the same
    shape as [EchoTruncation.agda], already cited by N2 in
    [formal/CROSS-REPO-MAP.adoc]. Merge (+) under a semilattice [resolve]
    is a JOIN; the conditional CRDT laws (R1-R3) are a candidate NEW
    echo-types abstraction (join-semilattice of partial sections), flagged
    for cross-documentation per the standing directive. See CROSS-REPO-MAP.

    Declared parameters: [mval], [ident]. Declared axioms:
    [functional_extensionality_dep] (Coq stdlib, for octad/function
    equality — the same whitelist entry as WAL.v and Normalizer.v).

    Build oracle: [just -f formal/Justfile octad]. CI: coq-build.yml.

    Tracking issue: hyperpolymath/verisimdb#77 (O-series + R1-R3).
*)

Require Import Coq.Lists.List.
Require Import Coq.Bool.Bool.
Require Import Coq.Logic.FunctionalExtensionality.

(* Keep Print Assumptions output on one line per axiom: the CI and Justfile
   guards match /^name :/ with awk, and Coq's default ~78-column wrap would
   split a longer axiom type across lines and silently escape the check. *)
Set Printing Width 400.

Import ListNotations.

(** ** [def:modset] — Modality Set

    The fixed eight-element basis M = {G,V,T,S,D,P,R,X}. Mirrors the eight
    boolean fields of [ModalityStatus]. *)
Inductive modality : Type :=
| Graph | Vector | Tensor | Semantic
| Document | Temporal | Provenance | Spatial.

Definition all_modalities : list modality :=
  [Graph; Vector; Tensor; Semantic; Document; Temporal; Provenance; Spatial].

(** O2 — modality cardinality: an octad has exactly eight modalities. *)
Theorem modality_cardinality : length all_modalities = 8.
Proof. reflexivity. Qed.

(** O2 — exhaustiveness: every modality is one of the eight. The CI
    tripwire for a ninth modality being added without updating the
    octad model. *)
Theorem modality_exhaustive : forall m, In m all_modalities.
Proof. intros m; destruct m; simpl; tauto. Qed.

(** Decidable equality on the finite modality enumeration. Proved by
    [decide equality]; introduces no axiom. *)
Definition modality_eq_dec (a b : modality) : {a = b} + {a <> b}.
Proof. decide equality. Defined.

(** ** [def:octad] — Octad: identity + modality function *)

(** Opaque per-modality value. Unifies the paper's Sigma_m; [None] models
    the paper's bot (absence of a representation in that modality). *)
Parameter mval : Type.

(** Opaque identifier (the paper's UUID). *)
Parameter ident : Type.

(** An octad: an identifier together with a modality function
    phi : modality -> option mval, where [None] = bot. *)
Record octad : Type := mk_octad {
  oid  : ident;
  ophi : modality -> option mval;
}.

(** Extensional octad equality: equal identifiers and equal modality
    functions imply equal octads. *)
Lemma octad_ext :
  forall o1 o2,
    oid o1 = oid o2 ->
    ophi o1 = ophi o2 ->
    o1 = o2.
Proof.
  intros [i1 p1] [i2 p2] Hid Hphi; simpl in *; subst; reflexivity.
Qed.

(** ** Presence, completeness, and the missing-set (O10) *)

Definition present (o : octad) (m : modality) : bool :=
  match ophi o m with Some _ => true | None => false end.

(** Mirrors [ModalityStatus::is_complete]: all eight modalities present. *)
Definition is_complete (o : octad) : bool :=
  forallb (present o) all_modalities.

(** Mirrors [ModalityStatus::missing]: the modalities that are bot. *)
Definition missing (o : octad) : list modality :=
  filter (fun m => negb (present o m)) all_modalities.

(** General bridge: a list is [forallb p]-true iff filtering by [negb . p]
    leaves nothing. *)
Lemma forallb_iff_filter_negb_nil :
  forall (A : Type) (p : A -> bool) (l : list A),
    forallb p l = true <-> filter (fun x => negb (p x)) l = [].
Proof.
  induction l as [|x xs IH]; simpl.
  - split; reflexivity.
  - destruct (p x); simpl.
    + exact IH.
    + split; intro H; discriminate H.
Qed.

(** O10 — present-totality: an octad is complete iff nothing is missing.
    Cross-checks [ModalityStatus::is_complete] against
    [ModalityStatus::missing]. *)
Theorem complete_iff_no_missing :
  forall o, is_complete o = true <-> missing o = [].
Proof.
  intros o. unfold is_complete, missing.
  apply forallb_iff_filter_negb_nil.
Qed.

(** ** [def:projection] — Projection pi_M

    Restrict the modality function to a mask [M : modality -> bool] (the
    paper's subset M of modality), sending masked-out modalities to bot. *)
Definition project (M : modality -> bool) (o : octad) : octad :=
  mk_octad (oid o) (fun m => if M m then ophi o m else None).

(** [inv:persist] for projection — identity is preserved. *)
Theorem project_preserves_id :
  forall M o, oid (project M o) = oid o.
Proof. reflexivity. Qed.

(** Projecting onto every modality is the identity. *)
Theorem project_full :
  forall o, project (fun _ => true) o = o.
Proof.
  intros o. apply octad_ext; [reflexivity|].
  apply functional_extensionality; intro m; reflexivity.
Qed.

(** Projection is idempotent. *)
Theorem project_idempotent :
  forall M o, project M (project M o) = project M o.
Proof.
  intros M o. apply octad_ext; [reflexivity|].
  apply functional_extensionality; intro m; simpl.
  destruct (M m); reflexivity.
Qed.

(** Projection composes as mask intersection: pi_M . pi_N = pi_{M /\ N}.
    The meet-semilattice law — the structural "modularity" of
    projections. *)
Theorem project_compose :
  forall M N o,
    project M (project N o) = project (fun m => andb (M m) (N m)) o.
Proof.
  intros M N o. apply octad_ext; [reflexivity|].
  apply functional_extensionality; intro m; simpl.
  destruct (M m), (N m); reflexivity.
Qed.

(** ** [def:merge] — Merge (+)

    [mcombine] is the per-modality merge kernel:
      bot (+) bot = bot;  v (+) bot = v;  bot (+) v = v;
      v1 (+) v2 = resolve v1 v2.
    [resolve] is the policy-dependent conflict resolver (the paper's
    [resolve]; [RegenerationStrategy] in the Rust source). It is an
    ARGUMENT of the operation, not a global axiom — the algebra laws below
    are implications from its properties. *)
Definition mcombine (resolve : mval -> mval -> mval)
                    (x y : option mval) : option mval :=
  match x, y with
  | None,   None   => None
  | Some a, None   => Some a
  | None,   Some b => Some b
  | Some a, Some b => Some (resolve a b)
  end.

(** Merge of two same-identifier octads. The result inherits the left
    operand's identifier; under the paper's precondition [oid o1 = oid o2]
    the choice of side is immaterial. *)
Definition merge (resolve : mval -> mval -> mval) (o1 o2 : octad) : octad :=
  mk_octad (oid o1) (fun m => mcombine resolve (ophi o1 m) (ophi o2 m)).

(** Merge preserves the (shared) identifier — [inv:persist]. *)
Theorem merge_preserves_id :
  forall resolve o1 o2, oid (merge resolve o1 o2) = oid o1.
Proof. reflexivity. Qed.

(** ** Proposition (Merge Commutativity) — MECHANISED

    The paper: "If resolve is commutative, then (+) is commutative."
    Its proof was one line; this is that proposition fully mechanised.
    The same-identifier hypothesis [oid o1 = oid o2] is the paper's
    "sharing the same identifier" precondition. *)
Theorem merge_commutative :
  forall resolve o1 o2,
    oid o1 = oid o2 ->
    (forall a b, resolve a b = resolve b a) ->
    merge resolve o1 o2 = merge resolve o2 o1.
Proof.
  intros resolve o1 o2 Hid Hcomm.
  apply octad_ext.
  - simpl. exact Hid.
  - apply functional_extensionality; intro m; simpl.
    destruct (ophi o1 m) as [a|], (ophi o2 m) as [b|]; simpl;
      try reflexivity.
    rewrite Hcomm. reflexivity.
Qed.

(** ** R2 — Merge associativity, under associative [resolve].

    The left-identifier convention makes (+) associative with NO identifier
    precondition: both nestings inherit [oid o1]. *)
Lemma mcombine_assoc :
  forall resolve,
    (forall a b c, resolve a (resolve b c) = resolve (resolve a b) c) ->
    forall x y z,
      mcombine resolve (mcombine resolve x y) z
      = mcombine resolve x (mcombine resolve y z).
Proof.
  intros resolve Hassoc x y z.
  destruct x as [a|], y as [b|], z as [c|]; simpl; try reflexivity.
  rewrite Hassoc. reflexivity.
Qed.

Theorem merge_associative :
  forall resolve o1 o2 o3,
    (forall a b c, resolve a (resolve b c) = resolve (resolve a b) c) ->
    merge resolve (merge resolve o1 o2) o3
    = merge resolve o1 (merge resolve o2 o3).
Proof.
  intros resolve o1 o2 o3 Hassoc.
  apply octad_ext; [reflexivity|].
  apply functional_extensionality; intro m; simpl.
  apply mcombine_assoc. exact Hassoc.
Qed.

(** ** R3 — Merge idempotence, under idempotent [resolve]. *)
Theorem merge_idempotent :
  forall resolve o,
    (forall a, resolve a a = a) ->
    merge resolve o o = o.
Proof.
  intros resolve o Hidem.
  apply octad_ext; [reflexivity|].
  apply functional_extensionality; intro m; simpl.
  destruct (ophi o m) as [a|]; simpl; [rewrite Hidem|]; reflexivity.
Qed.

(** ** [def:enrichment] — Enrichment

    [enrich m v o] sets modality [m] to [v] and leaves all others
    untouched (the paper's fundamental write primitive). *)
Definition enrich (m : modality) (v : mval) (o : octad) : octad :=
  mk_octad (oid o)
           (fun m' => if modality_eq_dec m' m then Some v else ophi o m').

(** [inv:persist]: enrichment never changes the identifier. *)
Theorem enrich_preserves_id :
  forall m v o, oid (enrich m v o) = oid o.
Proof. reflexivity. Qed.

(** Enrichment writes the target modality. *)
Theorem enrich_sets_target :
  forall m v o, ophi (enrich m v o) m = Some v.
Proof.
  intros m v o; simpl.
  destruct (modality_eq_dec m m); [reflexivity | congruence].
Qed.

(** Enrichment leaves every other modality untouched. *)
Theorem enrich_preserves_others :
  forall m v o m', m' <> m -> ophi (enrich m v o) m' = ophi o m'.
Proof.
  intros m v o m' Hneq; simpl.
  destruct (modality_eq_dec m' m); [congruence | reflexivity].
Qed.

(** After enrichment the target modality is present (not bot) — a local
    present-totality fact. *)
Theorem enrich_present :
  forall m v o, present (enrich m v o) m = true.
Proof.
  intros m v o. unfold present. rewrite enrich_sets_target. reflexivity.
Qed.

(** ** Print Assumptions guard

    Allowed: [mval], [ident] (Parameters) and [functional_extensionality_dep]
    (Coq stdlib). [modality] is inductive and [resolve] is an operation
    argument — neither is an axiom. Any other name fails the CI guard. *)

Print Assumptions modality_cardinality.
Print Assumptions modality_exhaustive.
Print Assumptions complete_iff_no_missing.
Print Assumptions project_full.
Print Assumptions project_idempotent.
Print Assumptions project_compose.
Print Assumptions merge_commutative.
Print Assumptions merge_associative.
Print Assumptions merge_idempotent.
Print Assumptions enrich_sets_target.
Print Assumptions enrich_preserves_others.
Print Assumptions enrich_present.
