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

public export
testAtThresholdNoFire : ProvisionallyProvenTest
testAtThresholdNoFire =
  provisionalTest (tid 1) "Drift at threshold does not trigger normalisation" (
    assertTrue (shouldNormalise 250 250 == False)
      "Equality is inside tolerance: firing at == would make the threshold a lie")

public export
testAboveThresholdFires : ProvisionallyProvenTest
testAboveThresholdFires =
  provisionalTest (tid 2) "Drift above threshold triggers normalisation" (
    assertTrue (shouldNormalise 251 250 == True)
      "The first permille above threshold must fire — no dead band")

public export
testZeroDriftNeverFires : ProvisionallyProvenTest
testZeroDriftNeverFires =
  provisionalTest (tid 3) "Zero drift never triggers normalisation" (
    assertTrue (shouldNormalise 0 0 == False && shouldNormalise 0 1000 == False)
      "A perfectly consistent octad must be left alone at any threshold")

public export
testGateMonotone : ProvisionallyProvenTest
testGateMonotone =
  provisionalTest (tid 4) "Gate is monotone in drift for a fixed threshold" (
    assertTrue (shouldNormalise 900 250 == True && shouldNormalise 100 250 == False)
      "More drift can never switch the gate off")

public export
allDriftTests : List ProvisionallyProvenTest
allDriftTests = [testAtThresholdNoFire, testAboveThresholdFires,
                 testZeroDriftNeverFires, testGateMonotone]
