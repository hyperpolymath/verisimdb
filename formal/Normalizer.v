(* SPDX-License-Identifier: MPL-2.0 *)
(* Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk> *)

(** * VeriSimDB Normalizer — N2 Idempotence

    Mechanises the foundation-pack theorem N2 (normalize_idempotent)
    for the normalizer in [rust-core/verisim-normalizer/].

    ** The original N2 spec gaps (verisimdb#91)

    Issue #91 captured three blockers preventing N2 as written:

      1) Merge non-idempotence — floating-point weighted averaging is
         not idempotent.
      2) LWW timestamp mutation — every regenerate call updates
         [modified_at] via [Utc::now()], changing the LWW winner on
         subsequent calls.
      3) No real ModalityRegenerator impls — only SummaryRegenerator
         stub exists.

    ** This module: prove N2 under a remediated spec

    We model normalize as: pick a deterministic WINNER among
    non-drifted modalities (LWW with frozen rank, NOT timestamp-based)
    and COPY its data to every drifted modality. The two spec choices
    that unblock #91 are baked in as axioms:

      [winner_excludes_drifted]
        The winner is never a drifted modality. Encodes "drift means
        the modality is corrupt; never copy FROM corrupt sources".

      [winner_stable_off_drifted]
        The winner depends only on the data of non-drifted modalities.
        Encodes "use frozen rank, not [Utc::now()]" — adding data to a
        drifted modality (which is what normalize itself does) does
        not change the winner choice.

    Under these two axioms N2 follows by a clean case split.

    Declared parameters: [modality], [modality_data], [winner],
    [drifted]. Declared axioms: the two listed above plus
    [functional_extensionality_dep] (from Coq stdlib).

    Tracking: hyperpolymath/verisimdb#77 + #91.
*)

Require Import Coq.Logic.FunctionalExtensionality.
Require Import Coq.Bool.Bool.

(* Keep Print Assumptions output on one line per axiom: the CI and Justfile
   guards match /^name :/ with awk, and Coq's default ~78-column wrap would
   split a longer axiom type across lines and silently escape the check. *)
Set Printing Width 400.


(** ** Domain *)

Parameter modality : Type.
Parameter modality_data : Type.

(** An octad is a partial assignment from modality to data. The Rust
    [Octad] struct carries optional fields for each of the 8
    modalities; we abstract over that layout here. *)
Definition octad : Type := modality -> option modality_data.

(** Whether a given modality is currently drifted (corrupt). In the
    Rust source this is a [DriftType -> bool] computed by the drift
    calculator. *)
Parameter drifted : modality -> bool.

(** The winner-selector function: given an octad, deterministically
    pick the modality (if any) to use as the authoritative source.
    [None] means "no source available" (every modality is empty or
    drifted), so normalize is a no-op. *)
Parameter winner : octad -> option modality.

(** Spec axiom 1 (closes #91 blocker 1+2 — Merge + timestamp):
    the winner is never a drifted modality. *)
Axiom winner_excludes_drifted :
  forall o m, winner o = Some m -> drifted m = false.

(** Spec axiom 2 (closes #91 blocker 2 — timestamp freeze):
    the winner depends only on the data of non-drifted modalities.
    Adding/changing data of a drifted modality does not change the
    winner. Encodes "rank is frozen, not [Utc::now()]". *)
Axiom winner_stable_off_drifted :
  forall o1 o2,
    (forall m, drifted m = false -> o1 m = o2 m) ->
    winner o1 = winner o2.

(** ** Normalize

    Pick the winner; if found, copy the winner's data to every
    drifted modality; if not, no-op. *)
Definition normalize (o : octad) : octad :=
  match winner o with
  | None => o
  | Some w =>
      match o w with
      | None => o
      | Some d =>
          fun m => if drifted m then Some d else o m
      end
  end.

(** ** Auxiliary lemma: non-drifted modalities are preserved *)
Lemma normalize_preserves_off_drifted :
  forall o m, drifted m = false -> normalize o m = o m.
Proof.
  intros o m Hnd. unfold normalize.
  destruct (winner o) as [w|]; [|reflexivity].
  destruct (o w) as [d|]; [|reflexivity].
  rewrite Hnd. reflexivity.
Qed.

(** ** Auxiliary lemma: the winner of [normalize o] equals the winner of [o] *)
Lemma normalize_preserves_winner :
  forall o, winner (normalize o) = winner o.
Proof.
  intros o. apply winner_stable_off_drifted.
  intros m Hnd. apply normalize_preserves_off_drifted. exact Hnd.
Qed.

(** ** Characterisation lemmas

    Three lemmas that pin down the value of [normalize o] in each
    branch of the implementation. *)

Lemma normalize_with_winner_data :
  forall o w d,
    winner o = Some w ->
    o w = Some d ->
    normalize o = (fun m => if drifted m then Some d else o m).
Proof.
  intros o w d Hw Hd. apply functional_extensionality. intros m.
  unfold normalize. rewrite Hw, Hd. reflexivity.
Qed.

Lemma normalize_winner_empty :
  forall o w, winner o = Some w -> o w = None -> normalize o = o.
Proof.
  intros o w Hw Hd. apply functional_extensionality. intros m.
  unfold normalize. rewrite Hw, Hd. reflexivity.
Qed.

Lemma normalize_no_winner :
  forall o, winner o = None -> normalize o = o.
Proof.
  intros o Hw. apply functional_extensionality. intros m.
  unfold normalize. rewrite Hw. reflexivity.
Qed.

(** ** N2: normalize is idempotent *)
Theorem normalize_idempotent :
  forall o, normalize (normalize o) = normalize o.
Proof.
  intros o.
  destruct (winner o) as [w|] eqn:Hw.
  - assert (Hnd : drifted w = false) by (eapply winner_excludes_drifted; exact Hw).
    destruct (o w) as [d|] eqn:Hd.
    + (* winner with data: go through an explicit intermediate lambda *)
      assert (Hwn : winner (normalize o) = Some w).
      { rewrite normalize_preserves_winner. exact Hw. }
      assert (Hnow : (normalize o) w = Some d).
      { rewrite (normalize_with_winner_data o w d Hw Hd).
        rewrite Hnd. exact Hd. }
      transitivity (fun m : modality => if drifted m then Some d else o m).
      * (* normalize (normalize o) = intermediate lambda *)
        transitivity
          (fun m : modality => if drifted m then Some d else (normalize o) m).
        -- apply (normalize_with_winner_data (normalize o) w d Hwn Hnow).
        -- apply functional_extensionality. intros m.
           destruct (drifted m) eqn:Hdm; [reflexivity|].
           apply normalize_preserves_off_drifted. exact Hdm.
      * (* intermediate lambda = normalize o *)
        symmetry. apply (normalize_with_winner_data o w d Hw Hd).
    + (* winner without data — normalize o = o *)
      assert (Hno : normalize o = o)
        by (apply (normalize_winner_empty o w Hw Hd)).
      congruence.
  - (* no winner — normalize o = o *)
    assert (Hno : normalize o = o) by (apply normalize_no_winner; exact Hw).
    congruence.
Qed.

(** ** Bonus: normalize is monotone in "drifted has a winner data".

    Once normalize lands a value into all drifted modalities, those
    modalities are no longer empty. This isn't N2 but is a useful
    sanity invariant for subsequent N1 (drift-decrease) work. *)
Theorem normalize_fills_drifted_when_winner :
  forall o m,
    drifted m = true ->
    (exists w, winner o = Some w /\ exists d, o w = Some d) ->
    exists d, normalize o m = Some d.
Proof.
  intros o m Hdm [w [Hw [d Hd]]].
  exists d. unfold normalize. rewrite Hw, Hd, Hdm. reflexivity.
Qed.

(** ** Print Assumptions guard *)

Print Assumptions normalize_idempotent.
Print Assumptions normalize_fills_drifted_when_winner.
