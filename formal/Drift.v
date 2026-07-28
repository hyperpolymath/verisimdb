(* SPDX-License-Identifier: MPL-2.0 *)
(* Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk> *)

(** * VeriSimDB Drift Score Unit-Interval Invariant

    Mechanises the foundation-pack theorem D1 (drift_score_in_unit_interval)
    for the drift modality defined in
    [rust-core/verisim-drift/src/calculator.rs].

    Every public drift-score function in calculator.rs ends with
    [.clamp(0.0, 1.0)] (audit confirmed all 9 of 9: semantic_vector_drift,
    graph_document_drift, temporal_consistency_drift, tensor_drift,
    provenance_drift, spatial_drift, schema_drift, quality_drift,
    quality_drift_octad). We abstract each as a [clamped] computation
    and prove the unit-interval invariant once at the general level,
    then derive 9 named corollaries — one per Rust function.

    The 9 corollaries serve as a CI tripwire: adding a 10th drift
    function to calculator.rs without a corresponding corollary here
    is the canonical "you forgot to clamp" signal.

    Declared axioms: 3 ordering laws on the abstract score type. No
    classical-reals dependency.

    Tracking issue: hyperpolymath/verisimdb#77 (follows #87 P2+P3).
*)

Require Import Coq.Init.Logic.

(* Keep Print Assumptions output on one line per axiom: the CI and Justfile
   guards match /^name :/ with awk, and Coq's default ~78-column wrap would
   split a longer axiom type across lines and silently escape the check. *)
Set Printing Width 400.

(* Keep Print Assumptions output on one line per axiom: the CI and Justfile
   guards match /^name :/ with awk, and Coq's default ~78-column wrap would
   split a longer axiom type across lines and silently escape the check. *)

(** ** Domain *)

(** Opaque score type. In the Rust source this is [f64]. *)
Parameter score : Type.

(** The constants 0.0 and 1.0. *)
Parameter zero : score.
Parameter one : score.

(** Order relation. *)
Parameter le : score -> score -> Prop.

(** Clamp: [clamp lo hi x] yields [max lo (min hi x)] in the Rust source. *)
Parameter clamp : score -> score -> score -> score.

(** Ordering and clamp laws — minimal axiomatisation. *)
Axiom le_refl : forall x : score, le x x.
Axiom clamp_lower : forall lo hi x : score, le lo (clamp lo hi x).
Axiom clamp_upper : forall lo hi x : score, le (clamp lo hi x) hi.

(** A score is in the unit interval if it is between [zero] and [one]. *)
Definition in_unit_interval (x : score) : Prop :=
  le zero x /\ le x one.

(** ** General lemma: every clamped computation is unit-interval-bound

    The Rust functions all have the form [.clamp(0.0, 1.0)] as their
    last operation. We model this as composing an arbitrary inner
    function [f] with [clamp zero one]. *)
Definition clamped (f : score -> score) : score -> score :=
  fun input => clamp zero one (f input).

Theorem clamped_in_unit_interval :
  forall (f : score -> score) (input : score),
    in_unit_interval (clamped f input).
Proof.
  intros f input. unfold in_unit_interval, clamped. split.
  - apply clamp_lower.
  - apply clamp_upper.
Qed.

(** ** D1 corollaries — one per Rust function

    Each [Parameter f_<name>] stands for the internal pre-clamp
    formula in the corresponding Rust function. Each corollary
    states that the [clamped]-wrapped version is unit-interval-bound. *)

Parameter f_semantic_vector_drift : score -> score.
Parameter f_graph_document_drift : score -> score.
Parameter f_temporal_consistency_drift : score -> score.
Parameter f_tensor_drift : score -> score.
Parameter f_provenance_drift : score -> score.
Parameter f_spatial_drift : score -> score.
Parameter f_schema_drift : score -> score.
Parameter f_quality_drift : score -> score.
Parameter f_quality_drift_octad : score -> score.

Definition semantic_vector_drift := clamped f_semantic_vector_drift.
Definition graph_document_drift := clamped f_graph_document_drift.
Definition temporal_consistency_drift := clamped f_temporal_consistency_drift.
Definition tensor_drift := clamped f_tensor_drift.
Definition provenance_drift := clamped f_provenance_drift.
Definition spatial_drift := clamped f_spatial_drift.
Definition schema_drift := clamped f_schema_drift.
Definition quality_drift := clamped f_quality_drift.
Definition quality_drift_octad := clamped f_quality_drift_octad.

Theorem semantic_vector_drift_in_unit_interval :
  forall input, in_unit_interval (semantic_vector_drift input).
Proof. intros. apply clamped_in_unit_interval. Qed.

Theorem graph_document_drift_in_unit_interval :
  forall input, in_unit_interval (graph_document_drift input).
Proof. intros. apply clamped_in_unit_interval. Qed.

Theorem temporal_consistency_drift_in_unit_interval :
  forall input, in_unit_interval (temporal_consistency_drift input).
Proof. intros. apply clamped_in_unit_interval. Qed.

Theorem tensor_drift_in_unit_interval :
  forall input, in_unit_interval (tensor_drift input).
Proof. intros. apply clamped_in_unit_interval. Qed.

Theorem provenance_drift_in_unit_interval :
  forall input, in_unit_interval (provenance_drift input).
Proof. intros. apply clamped_in_unit_interval. Qed.

Theorem spatial_drift_in_unit_interval :
  forall input, in_unit_interval (spatial_drift input).
Proof. intros. apply clamped_in_unit_interval. Qed.

Theorem schema_drift_in_unit_interval :
  forall input, in_unit_interval (schema_drift input).
Proof. intros. apply clamped_in_unit_interval. Qed.

Theorem quality_drift_in_unit_interval :
  forall input, in_unit_interval (quality_drift input).
Proof. intros. apply clamped_in_unit_interval. Qed.

Theorem quality_drift_octad_in_unit_interval :
  forall input, in_unit_interval (quality_drift_octad input).
Proof. intros. apply clamped_in_unit_interval. Qed.

(** ** D2: detect_drift_sound + detect_drift_complete

    The drift detector signals iff the score exceeds the threshold.
    Mirrors [DriftDetector::record] in
    [rust-core/verisim-drift/src/lib.rs], which returns [Some event]
    when [score > threshold] and [None] otherwise.

    This is the BOUNDARY direction — soundness ("if event then over
    threshold") plus completeness ("if no event then within
    threshold") at the threshold comparison. The deeper question of
    whether threshold-exceedance corresponds to a real consistency
    violation is the [score ↔ violation] gap (issue #80 territory).
    See verisimdb#77 D2 row + audit transcript in PR description. *)

(** The detector function: takes a score and a threshold and returns
    whether to emit a drift event. *)
Parameter f_detect_drift : score -> score -> bool.

(** Strict ordering. *)
Parameter strictly_greater : score -> score -> Prop.

(** Total ordering on [score]: for every pair [s, t], either [s <= t]
    or [s > t]. Faithful to the [f64] total order in the Rust source
    (modulo NaN, which the drift code rules out via clamp). *)
Axiom le_or_gt :
  forall s t, le s t \/ strictly_greater s t.

(** Strict-greater and weak-less-or-equal are mutually exclusive. *)
Axiom le_gt_exclusive :
  forall s t, ~ (le s t /\ strictly_greater s t).

(** The detector contract: [f_detect_drift score threshold = true]
    iff [score > threshold]. The Rust source implements this with
    an [if score > threshold] guard at lib.rs line 419. *)
Axiom detector_iff_threshold :
  forall s t, f_detect_drift s t = true <-> strictly_greater s t.

(** D2 soundness: a positive detector signal implies threshold is
    strictly exceeded (no false positives at the comparison boundary). *)
Theorem detect_drift_sound :
  forall s t, f_detect_drift s t = true -> strictly_greater s t.
Proof.
  intros s t Hdet. apply detector_iff_threshold. exact Hdet.
Qed.

(** D2 completeness: a negative detector signal implies the score is
    within threshold (no false negatives at the comparison boundary). *)
Theorem detect_drift_complete :
  forall s t, f_detect_drift s t = false -> le s t.
Proof.
  intros s t Hdet.
  destruct (le_or_gt s t) as [Hle | Hgt].
  - exact Hle.
  - exfalso.
    apply detector_iff_threshold in Hgt.
    rewrite Hgt in Hdet. discriminate.
Qed.

(** ** Print Assumptions guard

    Each theorem must close under the global context. The whitelist
    in the CI workflow allows: score, zero, one, le, clamp, le_refl,
    clamp_lower, clamp_upper, the 9 [f_*_drift] parameters, plus
    [f_detect_drift], [strictly_greater], [strictly_greater_iff_not_le],
    [detector_iff_threshold], [classic_le] (D2 additions). *)

Print Assumptions clamped_in_unit_interval.
Print Assumptions semantic_vector_drift_in_unit_interval.
Print Assumptions quality_drift_octad_in_unit_interval.
Print Assumptions detect_drift_sound.
Print Assumptions detect_drift_complete.
