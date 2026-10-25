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
import ProvenTests.Classification
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

||| Fixture pair (TEST-DOCTRINE §2 / standards R10), runtime-constructed
||| and actually evaluated by the fixture tests below: the silence
||| fixture must NOT fire, the firing fixture MUST fire. Classification
||| goes through `classifyProvisionallyProven` with this pair — the
||| legacy `provisionalTest` constructor carries FixtureDebt and its
||| tests are not counted in any evidence ledger.
private
fixtures : FixtureObligation
fixtures = Fixtures (MkFixturePair
  (MkSilenceFixture (RuntimeConstructed "isCompleteOctad allModalities in VeriSimTests.OctadTests.testFixtureSilence") "the canonical list carries every modality exactly once, so no defect is present")
  (MkFiringFixture (RuntimeConstructed "isCompleteOctad (take 7 allModalities) in VeriSimTests.OctadTests.testFixtureFiring") "an octad missing a modality (the declared defect class) must fail completeness"))

private
grade : TestId -> String -> IO TestResult -> ProvisionallyProvenTest
grade i d f = MkProvisionallyProvenTest
  (classifyProvisionallyProven i d provenTestsFrameworkProof (typeSafetyCert 6 "Dependent Types" "Idris2" ["VeriSimDB model invariants"]) fixtures) f

||| The completeness predicate both fixtures are judged by.
public export
isCompleteOctad : List Modality -> Bool
isCompleteOctad ms = length ms == 8 && length (nub (map slot ms)) == 8

public export
testExactlyEight : ProvisionallyProvenTest
testExactlyEight =
  grade (tid 1) "Octad has exactly eight modalities" (
    assertTrue (length allModalities == 8)
      "The octad invariant is 8 modalities; any other count is a different database")

public export
testSlotsDistinct : ProvisionallyProvenTest
testSlotsDistinct =
  grade (tid 2) "Modality slots are pairwise distinct" (
    assertTrue (length (nub (map slot allModalities)) == 8)
      "Two modalities sharing a slot would corrupt cross-modal identity")

public export
testSlotsCoverRange : ProvisionallyProvenTest
testSlotsCoverRange =
  grade (tid 3) "Slots cover 0..7 with no gaps" (
    assertTrue (sort (map slot allModalities) == [0, 1, 2, 3, 4, 5, 6, 7])
      "Slot assignment must be a bijection onto 0..7 for the octad vector layout")

public export
testFixtureSilence : ProvisionallyProvenTest
testFixtureSilence =
  grade (tid 4) "Fixture (silence): the full octad does not fire" (
    assertTrue (isCompleteOctad allModalities == True)
      "A fire on clean input is a harness fault")

public export
testFixtureFiring : ProvisionallyProvenTest
testFixtureFiring =
  grade (tid 5) "Fixture (firing): a seven-modality octad fires" (
    assertTrue (isCompleteOctad (take 7 allModalities) == False)
      "Silence on a defective input is a payload fault")

public export
allOctadTests : List ProvisionallyProvenTest
allOctadTests = [testExactlyEight, testSlotsDistinct, testSlotsCoverRange,
                 testFixtureSilence, testFixtureFiring]
