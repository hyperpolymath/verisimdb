(* SPDX-License-Identifier: MPL-2.0 *)
(* Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk> *)

(** * VeriSimDB Recovery Kernel (squeakwell rungs R2, R3, R4, R9, R10)

    Mechanises the REPAIRED recovery invariants of
    [hyperpolymath/squeakwell] (docs/ROUTE-PLAN.adoc, section 3 and the
    proof ladder in section 6) over the octad model of [Octad.v]. The
    original README invariants ("drift decreases monotonically", "fill is
    monotone", "resolve is a CRDT merge") were refuted during the 2026-11
    adversarial survey; what is proved here is the honest replacement.

    ** The recovery step

    One recovery round is [step propose o = normalise (fill propose o)]:

    - [fill propose] — GUARDED fill. For each modality that is bot it
      takes the oracle's proposal [propose o m]; a present modality is
      never overwritten. Stated as a LEFT-BIASED MERGE against the oracle's
      proposal octad, so it inherits [Octad.merge] and its identity law.
      The oracle is an ARGUMENT, never an axiom.
    - [normalise] — when the octad has at least one conflict, pick the
      [winner] modality and copy its value over every PRESENT modality;
      otherwise do nothing. Missing modalities stay missing (normalise
      never fills).

    ** What is proved (the repaired statements)

    - R2  Identity persistence: [oid (iter (step propose) n o) = oid o]
          for every oracle, every n. ([step_preserves_id], [iter_preserves_id])
    - R3  Guarded fill is INFLATIONARY on the information order
          ([fill_inflationary], [fill_guarded]). It is NOT monotone on that
          order: [fill_not_monotone] exhibits an oracle and two ordered
          octads whose fills are not ordered, whenever [mval] is inhabited.
          Both facts are per modality, so the six content modalities are
          covered; audit modalities (hash-chain prefix) live in
          [Provenance.v] and are intentionally not re-modelled.
    - R4  Counter-model: filling can RAISE the conflict count
          ([fill_can_raise_conflicts]). This is the formal statement of
          the runnable witness in verisim-api's drift_compute.rs: drift is
          OBSERVABLE, not monotone. Needs one conflicting pair of values.
    - R9  Permutation invariance of the merge fold under a semilattice
          resolve, for a same-identifier batch ([fold_merge_perm]); and the
          only kernel reachable today (PUT overwrite, [resolve a b = b]) is
          a NON-instance: it is commutative only if [mval] is a singleton
          ([put_commutative_iff_trivial]).
    - R10 Lexicographic progress on [mu o = (|missing o|, nconflicts o)]
          ([step_progress]: every round is a fixpoint or lex-decreases mu)
          and TERMINATION within nine rounds ([iter_9_fixpoint]).
          Hypotheses are EXPLICIT section variables: [conflict_refl]
          (no value conflicts with itself) and [winner_some] (whenever a
          conflict exists, the winner is a present modality).

    ** Honest scope

    [conflict] abstracts the pairwise-drift decision of
    verisim-drift (a boolean on two values); [nconflicts] counts ORDERED
    pairs of present modalities whose values conflict, so a distinct pair
    counts twice when [conflict] holds in both directions and once when it
    holds in only one ([conflict] is not assumed symmetric; the
    [fill_can_raise_conflicts] counter-model is symmetric, hence 0 -> 2).
    Either way it is a sound termination measure
    and keeps the definition free of a modality order. The winner is an
    abstract selector, exactly as in [Normalizer.v]; [winner_some] is the
    one property the termination argument needs (it replaces
    Normalizer.v's [winner_excludes_drifted] / [winner_stable_off_drifted],
    which are about the drift flag rather than about conflicts).

    Theory source of truth for R3/R9/R10 is echo-types (Agda); this file is
    the Rocq recheck inside the verisimdb formal tree, per
    standards/PROOF-POLICY. Mathesis grade is per theorem; see
    squeakwell/PROOF-STATUS.adoc.

    Declared parameters (inherited from [Octad.v]): [mval], [ident].
    Declared axioms: [functional_extensionality_dep] (Coq stdlib) — the same
    whitelist as [Octad.v]. Section variables are discharged into the
    theorem statements on [End]; nothing here is assumed globally.

    Build oracle: [just -f formal/Justfile recovery]. CI: coq-build.yml.
*)

Require Import Octad.
Require Import Coq.Lists.List.
Require Import Coq.Bool.Bool.
Require Import Coq.Arith.PeanoNat.
Require Import Coq.Sorting.Permutation.
Require Import Coq.Logic.FunctionalExtensionality.
Require Import Lia.

Set Printing Width 400.

Import ListNotations.

(** ** Generic list lemmas *)

Lemma filter_length_le_mono :
  forall (A : Type) (p q : A -> bool) (l : list A),
    (forall x, In x l -> p x = true -> q x = true) ->
    length (filter (fun x => negb (q x)) l)
    <= length (filter (fun x => negb (p x)) l).
Proof.
  intros A p q l H.
  induction l as [|x xs IH]; simpl.
  - lia.
  - assert (IH' : length (filter (fun x => negb (q x)) xs)
                  <= length (filter (fun x => negb (p x)) xs)).
    { apply IH. intros y Hy. apply H. right. exact Hy. }
    destruct (p x) eqn:Hp.
    + rewrite (H x (or_introl eq_refl) Hp). simpl. exact IH'.
    + destruct (q x); simpl; lia.
Qed.

Lemma filter_length_eq_pointwise :
  forall (A : Type) (p q : A -> bool) (l : list A),
    (forall x, In x l -> p x = true -> q x = true) ->
    length (filter (fun x => negb (q x)) l)
    = length (filter (fun x => negb (p x)) l) ->
    forall x, In x l -> q x = p x.
Proof.
  intros A p q l H Heq.
  induction l as [|x xs IH]; simpl in *.
  - intros x [].
  - assert (Hmono : length (filter (fun x => negb (q x)) xs)
                    <= length (filter (fun x => negb (p x)) xs)).
    { apply filter_length_le_mono. intros y Hy. apply H. right. exact Hy. }
    destruct (p x) eqn:Hp.
    + assert (Hq : q x = true) by (apply H; [left; reflexivity | exact Hp]).
      rewrite Hq in Heq. simpl in Heq.
      intros y [Hy | Hy].
      * subst y. rewrite Hq, Hp. reflexivity.
      * apply IH; [intros z Hz; apply H; right; exact Hz | exact Heq | exact Hy].
    + destruct (q x) eqn:Hq; simpl in Heq.
      * (* lhs skips x, rhs counts it: contradicts Heq *)
        lia.
      * intros y [Hy | Hy].
        { subst y. rewrite Hq, Hp. reflexivity. }
        { apply IH; [intros z Hz; apply H; right; exact Hz | lia | exact Hy]. }
Qed.

Lemma filter_nil_of_all_false :
  forall (A : Type) (f : A -> bool) (l : list A),
    (forall x, In x l -> f x = false) -> filter f l = [].
Proof.
  intros A f l H. induction l as [|x xs IH]; simpl.
  - reflexivity.
  - rewrite (H x (or_introl eq_refl)). apply IH. intros y Hy. apply H. right. exact Hy.
Qed.

Lemma filter_length_le_length :
  forall (A : Type) (f : A -> bool) (l : list A),
    length (filter f l) <= length l.
Proof.
  intros A f l. induction l as [|x xs IH]; simpl; [lia|].
  destruct (f x); simpl; lia.
Qed.

(** ** Information order and the guarded fill (R3) *)

(** The information order on octads: every value present in [o1] is
    present, unchanged, in [o2]. *)
Definition info_le (o1 o2 : octad) : Prop :=
  forall m v, ophi o1 m = Some v -> ophi o2 m = Some v.

(** The oracle's proposal, packaged as an octad with the same identifier,
    so that fill is literally a merge. *)
Definition proposal (propose : octad -> modality -> option mval) (o : octad) : octad :=
  mk_octad (oid o) (propose o).

(** Left-biased resolve: keep what is already there. *)
Definition keep_left (a _ : mval) : mval := a.

(** Guarded fill = left-biased merge against the oracle's proposal. *)
Definition fill (propose : octad -> modality -> option mval) (o : octad) : octad :=
  merge keep_left o (proposal propose o).

Lemma fill_phi :
  forall propose o m,
    ophi (fill propose o) m
    = match ophi o m with
      | Some v => Some v
      | None => propose o m
      end.
Proof.
  intros propose o m. unfold fill, merge, proposal, mcombine. simpl.
  destruct (ophi o m) as [v|]; destruct (propose o m); reflexivity.
Qed.

Theorem fill_preserves_id :
  forall propose o, oid (fill propose o) = oid o.
Proof. reflexivity. Qed.

(** R3 — a present modality is never overwritten (the guard). *)
Theorem fill_guarded :
  forall propose o m v, ophi o m = Some v -> ophi (fill propose o) m = Some v.
Proof. intros propose o m v H. rewrite fill_phi, H. reflexivity. Qed.

(** R3 — guarded fill is inflationary on the information order. *)
Theorem fill_inflationary :
  forall propose o, info_le o (fill propose o).
Proof. intros propose o m v H. apply fill_guarded. exact H. Qed.

Lemma fill_present :
  forall propose o m, present o m = true -> present (fill propose o) m = true.
Proof.
  intros propose o m H. unfold present in *. rewrite fill_phi.
  destruct (ophi o m); [reflexivity | discriminate].
Qed.

Lemma fill_missing_le :
  forall propose o,
    length (missing (fill propose o)) <= length (missing o).
Proof.
  intros propose o. unfold missing.
  apply filter_length_le_mono. intros m _ H. apply fill_present. exact H.
Qed.

(** If fill does not strictly shrink the missing set, it is the identity:
    every proposal the oracle made was for a modality already present
    (or the oracle proposed nothing). *)
Lemma fill_missing_eq_fixpoint :
  forall propose o,
    length (missing (fill propose o)) = length (missing o) ->
    fill propose o = o.
Proof.
  intros propose o Heq.
  assert (Hpres : forall m, present (fill propose o) m = present o m).
  { intros m. unfold missing in Heq.
    eapply (filter_length_eq_pointwise modality (present o) (present (fill propose o))).
    - intros x _ H. apply fill_present. exact H.
    - exact Heq.
    - apply modality_exhaustive. }
  apply octad_ext; [reflexivity|].
  apply functional_extensionality; intro m.
  specialize (Hpres m). unfold present in Hpres. rewrite fill_phi in *.
  destruct (ophi o m) as [v|]; [reflexivity|].
  destruct (propose o m); [discriminate | reflexivity].
Qed.

(** R3 (negative half) — guarded fill is NOT monotone on the information
    order: an oracle that proposes a value only while a modality is
    missing sends [o1 ⊑ o2] to incomparable fills. Stated for any
    inhabitant of [mval]; nothing is assumed about [mval] globally. *)
Section FillNotMonotone.
  Variable v : mval.

  (* Propose [v] for Vector whenever Graph is still missing. *)
  Definition propose_cm (o : octad) (m : modality) : option mval :=
    match m with
    | Vector => if present o Graph then None else Some v
    | _ => None
    end.

  Definition empty_octad (i : ident) : octad := mk_octad i (fun _ => None).
  Definition graph_octad (i : ident) : octad :=
    mk_octad i (fun m => match m with Graph => Some v | _ => None end).

  Theorem fill_not_monotone :
    forall i,
      info_le (empty_octad i) (graph_octad i)
      /\ ~ info_le (fill propose_cm (empty_octad i)) (fill propose_cm (graph_octad i)).
  Proof.
    intros i. split.
    - intros m w H. simpl in H. discriminate.
    - intro Hmono.
      specialize (Hmono Vector v).
      rewrite fill_phi in Hmono. rewrite fill_phi in Hmono. simpl in Hmono.
      specialize (Hmono eq_refl). discriminate.
  Qed.
End FillNotMonotone.

(** ** Conflicts (R4) *)

Section Conflicts.
  (** Pairwise conflict decision on values (abstracts verisim-drift's
      per-pair drift test). *)
  Variable conflict : mval -> mval -> bool.

  Definition conflict_at (o : octad) (p : modality * modality) : bool :=
    match ophi o (fst p), ophi o (snd p) with
    | Some a, Some b => conflict a b
    | _, _ => false
    end.

  Definition pairs : list (modality * modality) :=
    list_prod all_modalities all_modalities.

  (** Number of ORDERED conflicting pairs of present modalities. *)
  Definition nconflicts (o : octad) : nat :=
    length (filter (conflict_at o) pairs).

  (** R4 — counter-model: one conflicting pair of values suffices for a
      guarded fill to RAISE the conflict count from 0 to 2. This is the
      mechanised form of the runnable witness in drift_compute.rs. *)
  Section CounterModel.
    Variables a b : mval.
    Hypothesis conflict_aa : conflict a a = false.
    Hypothesis conflict_bb : conflict b b = false.
    Hypothesis conflict_ab : conflict a b = true.
    Hypothesis conflict_ba : conflict b a = true.

    Definition propose_b (_ : octad) (m : modality) : option mval :=
      match m with Vector => Some b | _ => None end.

    Definition only_graph (i : ident) : octad :=
      mk_octad i (fun m => match m with Graph => Some a | _ => None end).

    Lemma only_graph_no_conflicts :
      forall i, nconflicts (only_graph i) = 0.
    Proof.
      intros i. unfold nconflicts.
      rewrite (filter_nil_of_all_false _ (conflict_at (only_graph i)) pairs); [reflexivity|].
      intros [m1 m2] _. unfold conflict_at, only_graph. simpl.
      destruct m1, m2; simpl; try reflexivity. exact conflict_aa.
    Qed.

    Lemma in_length_pos :
      forall (A : Type) (x : A) (l : list A), In x l -> 1 <= length l.
    Proof. intros A x l H. destruct l; [destruct H | simpl; lia]. Qed.

    Theorem fill_can_raise_conflicts :
      forall i,
        nconflicts (only_graph i) < nconflicts (fill propose_b (only_graph i)).
    Proof.
      intros i. rewrite only_graph_no_conflicts. unfold nconflicts.
      apply (in_length_pos _ (Graph, Vector)).
      apply filter_In. split.
      - unfold pairs. apply in_prod; apply modality_exhaustive.
      - unfold conflict_at. simpl. exact conflict_ab.
    Qed.
  End CounterModel.

  (** ** Normalise and the lexicographic measure (R10) *)

  (** Abstract winner selector (as in [Normalizer.v]). *)
  Variable winner : octad -> option modality.

  (** [conflict_refl]: no value conflicts with itself. The one property
      of the conflict test the termination argument needs. *)
  Hypothesis conflict_refl : forall x, conflict x x = false.

  (** [winner_some]: whenever there is a conflict, the winner is a
      PRESENT modality. Replaces Normalizer.v's drift-flag axioms with the
      conflict-relative statement the recovery kernel actually uses. *)
  Hypothesis winner_some :
    forall o, nconflicts o <> 0 ->
      exists w d, winner o = Some w /\ ophi o w = Some d.

  (** Overwrite every PRESENT modality with [d]; leave bot alone. *)
  Definition overwrite_present (d : mval) (o : octad) : octad :=
    mk_octad (oid o)
             (fun m => match ophi o m with Some _ => Some d | None => None end).

  (** Normalise: act only when there is a conflict to resolve. *)
  Definition normalise (o : octad) : octad :=
    if Nat.eqb (nconflicts o) 0 then o
    else match winner o with
         | None => o
         | Some w =>
             match ophi o w with
             | Some d => overwrite_present d o
             | None => o
             end
         end.

  Lemma overwrite_present_present :
    forall d o m, present (overwrite_present d o) m = present o m.
  Proof.
    intros d o m. unfold present, overwrite_present. simpl.
    destruct (ophi o m); reflexivity.
  Qed.

  Lemma overwrite_present_no_conflicts :
    forall d o, nconflicts (overwrite_present d o) = 0.
  Proof.
    intros d o. unfold nconflicts.
    rewrite (filter_nil_of_all_false _ (conflict_at (overwrite_present d o)) pairs);
      [reflexivity|].
    intros [m1 m2] _. unfold conflict_at, overwrite_present. simpl.
    destruct (ophi o m1), (ophi o m2); try reflexivity. apply conflict_refl.
  Qed.

  Theorem normalise_preserves_id :
    forall o, oid (normalise o) = oid o.
  Proof.
    intros o. unfold normalise.
    destruct (Nat.eqb (nconflicts o) 0); [reflexivity|].
    destruct (winner o) as [w|]; [|reflexivity].
    destruct (ophi o w); reflexivity.
  Qed.

  Lemma normalise_present :
    forall o m, present (normalise o) m = present o m.
  Proof.
    intros o m. unfold normalise.
    destruct (Nat.eqb (nconflicts o) 0); [reflexivity|].
    destruct (winner o) as [w|]; [|reflexivity].
    destruct (ophi o w); [apply overwrite_present_present | reflexivity].
  Qed.

  Lemma normalise_missing :
    forall o, missing (normalise o) = missing o.
  Proof.
    intros o. unfold missing. apply filter_ext_in. intros m _.
    rewrite normalise_present. reflexivity.
  Qed.

  (** After normalise there are no conflicts: either there were none and
      normalise was the identity, or the winner's value now sits in every
      present modality. *)
  Theorem normalise_no_conflicts :
    forall o, nconflicts (normalise o) = 0.
  Proof.
    intros o. unfold normalise.
    destruct (Nat.eqb (nconflicts o) 0) eqn:Hz.
    - apply Nat.eqb_eq in Hz. exact Hz.
    - apply Nat.eqb_neq in Hz.
      destruct (winner_some o Hz) as [w [d [Hw Hd]]].
      rewrite Hw, Hd. apply overwrite_present_no_conflicts.
  Qed.

  Lemma normalise_zero_fixpoint :
    forall o, nconflicts o = 0 -> normalise o = o.
  Proof.
    intros o H. unfold normalise. rewrite H. reflexivity.
  Qed.

  (** ** The recovery round *)

  Variable propose : octad -> modality -> option mval.

  Definition step (o : octad) : octad := normalise (fill propose o).

  Fixpoint iter (n : nat) (o : octad) : octad :=
    match n with
    | 0 => o
    | S k => iter k (step o)
    end.

  (** R2 — identity persistence through every round. *)
  Theorem step_preserves_id : forall o, oid (step o) = oid o.
  Proof. intros o. unfold step. rewrite normalise_preserves_id. reflexivity. Qed.

  Theorem iter_preserves_id : forall n o, oid (iter n o) = oid o.
  Proof.
    induction n as [|k IH]; intros o; cbn [iter]; [reflexivity|].
    rewrite IH. apply step_preserves_id.
  Qed.

  Lemma iter_fixpoint : forall n o, step o = o -> iter n o = o.
  Proof.
    induction n as [|k IH]; intros o H; cbn [iter]; [reflexivity|].
    rewrite H. apply IH. exact H.
  Qed.

  (** The lexicographic measure. *)
  Definition mu (o : octad) : nat * nat := (length (missing o), nconflicts o).

  Definition lex_lt (p q : nat * nat) : Prop :=
    fst p < fst q \/ (fst p = fst q /\ snd p < snd q).

  Lemma step_missing_le :
    forall o, length (missing (step o)) <= length (missing o).
  Proof. intros o. unfold step. rewrite normalise_missing. apply fill_missing_le. Qed.

  Lemma step_no_conflicts : forall o, nconflicts (step o) = 0.
  Proof. intros o. unfold step. apply normalise_no_conflicts. Qed.

  (** A round that does not shrink the missing set, on a conflict-free
      octad, is the identity. *)
  Lemma step_stall_fixpoint :
    forall o, nconflicts o = 0 ->
      length (missing (step o)) = length (missing o) -> step o = o.
  Proof.
    intros o Hc Hm. unfold step in *. rewrite normalise_missing in Hm.
    rewrite (fill_missing_eq_fixpoint propose o Hm).
    apply normalise_zero_fixpoint. exact Hc.
  Qed.

  (** R10 — lexicographic progress: every round is a fixpoint or strictly
      decreases [mu] in the lexicographic order. The first component
      (missing count) drops when fill does work; otherwise the second
      (conflict count) drops to zero. *)
  Theorem step_progress :
    forall o, step o = o \/ lex_lt (mu (step o)) (mu o).
  Proof.
    intros o.
    destruct (Nat.lt_ge_cases (length (missing (step o))) (length (missing o))) as [Hlt | Hge].
    - right. unfold lex_lt, mu. left. exact Hlt.
    - assert (Heq : length (missing (step o)) = length (missing o)).
      { pose proof (step_missing_le o). lia. }
      destruct (Nat.eq_dec (nconflicts o) 0) as [Hz | Hnz].
      + left. apply step_stall_fixpoint; assumption.
      + right. unfold lex_lt, mu. right. split; [exact Heq|].
        change (nconflicts (step o) < nconflicts o).
        rewrite step_no_conflicts. lia.
  Qed.

  (** Bounded descent on the missing count once conflicts are gone. *)
  Lemma iter_bounded :
    forall n o, nconflicts o = 0 -> length (missing o) <= n ->
      step (iter n o) = iter n o.
  Proof.
    induction n as [|k IH]; intros o Hc Hm; cbn [iter].
    - (* nothing missing: fill cannot shrink, so the round is the identity *)
      apply step_stall_fixpoint; [exact Hc|].
      pose proof (step_missing_le o). lia.
    - destruct (Nat.lt_ge_cases (length (missing (step o))) (length (missing o))) as [Hlt | Hge].
      + apply IH; [apply step_no_conflicts | lia].
      + assert (Heq : length (missing (step o)) = length (missing o)).
        { pose proof (step_missing_le o). lia. }
        assert (Hfix : step o = o) by (apply step_stall_fixpoint; assumption).
        rewrite Hfix. rewrite (iter_fixpoint k o Hfix). exact Hfix.
  Qed.

  Lemma iter_unfold : forall n o, iter (S n) o = iter n (step o).
  Proof. intros n o. reflexivity. Qed.

  (** R10 — termination: nine rounds always reach a fixpoint. Round one
      clears every conflict; each later round either fills at least one of
      the at most eight missing modalities or is already the fixpoint. *)
  Theorem iter_9_fixpoint :
    forall o, step (iter 9 o) = iter 9 o.
  Proof.
    intros o. rewrite (iter_unfold 8 o).
    apply iter_bounded; [apply step_no_conflicts|].
    unfold missing. etransitivity; [apply filter_length_le_length|].
    rewrite modality_cardinality. lia.
  Qed.

  (** The fixpoint reached is conflict-free. *)
  Lemma iter_succ_no_conflicts :
    forall k o, nconflicts (iter (S k) o) = 0.
  Proof.
    induction k as [|k IH]; intros o; cbn [iter].
    - apply step_no_conflicts.
    - apply IH.
  Qed.

  Theorem iter_9_no_conflicts :
    forall o, nconflicts (iter 9 o) = 0.
  Proof. intros o. apply (iter_succ_no_conflicts 8). Qed.

End Conflicts.

(** ** Permutation invariance of the merge fold (R9) *)

Section PermutationInvariance.
  Variable resolve : mval -> mval -> mval.
  Hypothesis resolve_comm : forall a b, resolve a b = resolve b a.
  Hypothesis resolve_assoc :
    forall a b c, resolve a (resolve b c) = resolve (resolve a b) c.

  Definition fold_merge (acc : octad) (l : list octad) : octad :=
    fold_left (merge resolve) l acc.

  (** All octads in a batch share one identifier (the paper's "same
      identifier" precondition on merge). *)
  Definition same_id (i : ident) (l : list octad) : Prop :=
    Forall (fun o => oid o = i) l.

  Lemma same_id_perm :
    forall i l1 l2, Permutation l1 l2 -> same_id i l1 -> same_id i l2.
  Proof.
    intros i l1 l2 Hp H. unfold same_id in *. rewrite Forall_forall in *.
    intros o Ho. apply H. eapply Permutation_in; [apply Permutation_sym; exact Hp | exact Ho].
  Qed.

  Lemma merge_swap :
    forall acc x y, oid x = oid y ->
      merge resolve (merge resolve acc x) y = merge resolve (merge resolve acc y) x.
  Proof.
    intros acc x y Hid.
    rewrite (merge_associative resolve acc x y resolve_assoc).
    rewrite (merge_commutative resolve x y Hid resolve_comm).
    rewrite <- (merge_associative resolve acc y x resolve_assoc).
    reflexivity.
  Qed.

  (** R9 — under a commutative, associative [resolve], the order in which a
      same-identifier batch is merged does not matter. *)
  Theorem fold_merge_perm :
    forall i l1 l2 acc,
      same_id i l1 -> Permutation l1 l2 ->
      fold_merge acc l1 = fold_merge acc l2.
  Proof.
    intros i l1 l2 acc Hid Hp. revert acc Hid.
    induction Hp as [| x l1 l2 Hp IH | x y l | l1 l2 l3 Hp1 IH1 Hp2 IH2];
      intros acc Hid; unfold fold_merge in *; simpl.
    - reflexivity.
    - apply IH. inversion Hid; assumption.
    - inversion Hid as [| ? ? Hy Hrest]; subst. inversion Hrest as [| ? ? Hx _]; subst.
      rewrite (merge_swap acc y x); [reflexivity | congruence].
    - rewrite (IH1 acc Hid). apply IH2. eapply same_id_perm; eassumption.
  Qed.
End PermutationInvariance.

(** R9 (negative half) — the PUT-overwrite kernel [resolve a b = b], the
    only resolve reachable through verisim-api today, is commutative only
    when [mval] has at most one value. So it is NOT an instance of R9. *)
Definition resolve_put (_ b : mval) : mval := b.

Theorem put_commutative_iff_trivial :
  (forall a b, resolve_put a b = resolve_put b a) <-> (forall a b : mval, a = b).
Proof.
  unfold resolve_put. split.
  - intros H a b. rewrite (H b a). reflexivity.
  - intros H a b. apply H.
Qed.

(** ** Print Assumptions guard

    Allowed: [mval], [ident] (Parameters of Octad.v) and
    [functional_extensionality_dep] (Coq stdlib). Section variables and
    hypotheses have been discharged into the statements. *)

Print Assumptions fill_guarded.
Print Assumptions fill_inflationary.
Print Assumptions fill_not_monotone.
Print Assumptions fill_can_raise_conflicts.
Print Assumptions normalise_no_conflicts.
Print Assumptions step_preserves_id.
Print Assumptions iter_preserves_id.
Print Assumptions step_progress.
Print Assumptions iter_9_fixpoint.
Print Assumptions iter_9_no_conflicts.
Print Assumptions fold_merge_perm.
Print Assumptions put_commutative_iff_trivial.
