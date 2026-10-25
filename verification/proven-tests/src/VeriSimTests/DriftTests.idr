-- SPDX-License-Identifier: MPL-2.0
--
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <jonathan.jewell@open.ac.uk>
--
-- Model-level drift-gating invariants (rust-core/verisim-drift implements
-- the production scorer in floating point; the gate shape is pinned here in
-- exact integer permille so the *policy* — normalise iff drift exceeds the
-- threshold, never at or below it — is a graded, typechecked artefact).

module VeriSimTests.DriftTests

import ProvenTests.Framework
import ProvenTests.Types
import ProvenTests.Classification

%default total

||| Drift score in permille, 0..1000.
public export
Drift : Type
Drift = Nat

||| The gate: automatic normalisation fires iff drift exceeds threshold.
public export
shouldNormalise : Drift -> Drift -> Bool
shouldNormalise drift threshold = drift > threshold

private
tid : Nat -> TestId
tid n = MkTestId "VeriSimTests.DriftTests" ("test_" ++ show n) n

||| Fixture pair (TEST-DOCTRINE §2 / standards R10), runtime-constructed
||| and actually evaluated by the fixture tests below: the silence
||| fixture must NOT fire, the firing fixture MUST fire. Classification
||| goes through `classifyProvisionallyProven` with this pair — the
||| legacy `provisionalTest` constructor carries FixtureDebt and its
||| tests are not counted in any evidence ledger.
private
fixtures : FixtureObligation
fixtures = Fixtures (MkFixturePair
  (MkSilenceFixture (RuntimeConstructed "modelDrift h h (identical content hash) in VeriSimTests.DriftTests.testFixtureSilence") "identical content carries zero drift, so the gate must stay silent")
  (MkFiringFixture (RuntimeConstructed "modelDrift h h' (changed content hash) in VeriSimTests.DriftTests.testFixtureFiring") "drifted content (the declared defect class) must fire the gate"))

private
grade : TestId -> String -> IO TestResult -> ProvisionallyProvenTest
grade i d f = MkProvisionallyProvenTest
  (classifyProvisionallyProven i d provenTestsFrameworkProof (typeSafetyCert 6 "Dependent Types" "Idris2" ["VeriSimDB model invariants"]) fixtures) f

||| Content-hash drift model: identical hashes drift 0, differing drift 1000.
||| (The production scorer interpolates; the gate policy is what is pinned.)
public export
modelDrift : Nat -> Nat -> Drift
modelDrift a b = if a == b then 0 else 1000

public export
testAtThresholdNoFire : ProvisionallyProvenTest
testAtThresholdNoFire =
  grade (tid 1) "Drift at threshold does not trigger normalisation" (
    assertTrue (shouldNormalise 250 250 == False)
      "Equality is inside tolerance: firing at == would make the threshold a lie")

public export
testAboveThresholdFires : ProvisionallyProvenTest
testAboveThresholdFires =
  grade (tid 2) "Drift above threshold triggers normalisation" (
    assertTrue (shouldNormalise 251 250 == True)
      "The first permille above threshold must fire — no dead band")

public export
testZeroDriftNeverFires : ProvisionallyProvenTest
testZeroDriftNeverFires =
  grade (tid 3) "Zero drift never triggers normalisation" (
    assertTrue (shouldNormalise 0 0 == False && shouldNormalise 0 1000 == False)
      "A perfectly consistent octad must be left alone at any threshold")

public export
testGateMonotone : ProvisionallyProvenTest
testGateMonotone =
  grade (tid 4) "Gate is monotone in drift for a fixed threshold" (
    assertTrue (shouldNormalise 900 250 == True && shouldNormalise 100 250 == False)
      "More drift can never switch the gate off")

public export
testFixtureSilence : ProvisionallyProvenTest
testFixtureSilence =
  grade (tid 5) "Fixture (silence): identical content does not fire" (
    assertTrue (modelDrift 4242 4242 == 0 && shouldNormalise (modelDrift 4242 4242) 250 == False)
      "A fire on clean input is a harness fault")

public export
testFixtureFiring : ProvisionallyProvenTest
testFixtureFiring =
  grade (tid 6) "Fixture (firing): changed content fires" (
    assertTrue (modelDrift 4242 9999 == 1000 && shouldNormalise (modelDrift 4242 9999) 250 == True)
      "Silence on a defective input is a payload fault")

public export
allDriftTests : List ProvisionallyProvenTest
allDriftTests = [testAtThresholdNoFire, testAboveThresholdFires,
                 testZeroDriftNeverFires, testGateMonotone,
                 testFixtureSilence, testFixtureFiring]
