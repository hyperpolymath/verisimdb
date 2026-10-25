-- SPDX-License-Identifier: MPL-2.0
--
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <jonathan.jewell@open.ac.uk>
--
-- Model-level octad invariants for VeriSimDB, graded with
-- hyperpolymath/proven-tests-and-benches. These tests pin the *model* the
-- Rust crates implement (rust-core/verisim-octad): exactly eight modalities,
-- pairwise distinct, and a total modality -> slot assignment. The Rust
-- implementation itself is tested by cargo (verification/test-registry.json,
-- suite rust-unit-integration); this suite's job is to make the model's
-- shape a typechecked, tier-graded artefact that cannot quietly drift.

module VeriSimTests.OctadTests

import ProvenTests.Framework
import ProvenTests.Types
import Data.List

%default total

||| The eight modalities of the octad, in canonical slot order.
public export
data Modality = Graph | Vector | Tensor | Semantic
              | Document | Temporal | Provenance | Spatial

public export
Eq Modality where
  Graph == Graph = True
  Vector == Vector = True
  Tensor == Tensor = True
  Semantic == Semantic = True
  Document == Document = True
  Temporal == Temporal = True
  Provenance == Provenance = True
  Spatial == Spatial = True
  _ == _ = False

||| Every modality, exactly once, in slot order.
public export
allModalities : List Modality
allModalities = [Graph, Vector, Tensor, Semantic, Document, Temporal, Provenance, Spatial]

||| Canonical slot index of a modality (0-based, total).
public export
slot : Modality -> Nat
slot Graph = 0
slot Vector = 1
slot Tensor = 2
slot Semantic = 3
slot Document = 4
slot Temporal = 5
slot Provenance = 6
slot Spatial = 7

private
tid : Nat -> TestId
tid n = MkTestId "VeriSimTests.OctadTests" ("test_" ++ show n) n

public export
testExactlyEight : ProvisionallyProvenTest
testExactlyEight =
  provisionalTest (tid 1) "Octad has exactly eight modalities" (
    assertTrue (length allModalities == 8)
      "The octad invariant is 8 modalities; any other count is a different database")

public export
testSlotsDistinct : ProvisionallyProvenTest
testSlotsDistinct =
  provisionalTest (tid 2) "Modality slots are pairwise distinct" (
    assertTrue (length (nub (map slot allModalities)) == 8)
      "Two modalities sharing a slot would corrupt cross-modal identity")

public export
testSlotsCoverRange : ProvisionallyProvenTest
testSlotsCoverRange =
  provisionalTest (tid 3) "Slots cover 0..7 with no gaps" (
    assertTrue (sort (map slot allModalities) == [0, 1, 2, 3, 4, 5, 6, 7])
      "Slot assignment must be a bijection onto 0..7 for the octad vector layout")

public export
allOctadTests : List ProvisionallyProvenTest
allOctadTests = [testExactlyEight, testSlotsDistinct, testSlotsCoverRange]
