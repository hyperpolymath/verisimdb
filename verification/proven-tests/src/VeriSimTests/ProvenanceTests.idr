-- SPDX-License-Identifier: MPL-2.0
--
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <jonathan.jewell@open.ac.uk>
--
-- Model-level provenance-chain invariants (rust-core/verisim-provenance
-- implements the production hash chain; Coq development in formal/ carries
-- the actually-proven tier for the chain theorems). Here the append-only
-- shape is pinned: extending a chain preserves its prefix and grows its
-- length by exactly one.

module VeriSimTests.ProvenanceTests

import ProvenTests.Framework
import ProvenTests.Types
import ProvenTests.Classification
import Data.List

%default total

||| A provenance chain is an append-only list of entry digests (modelled as
||| Nat hashes; the production type is a 32-byte digest).
public export
Chain : Type
Chain = List Nat

public export
appendEntry : Chain -> Nat -> Chain
appendEntry chain digest = chain ++ [digest]

private
tid : Nat -> TestId
tid n = MkTestId "VeriSimTests.ProvenanceTests" ("test_" ++ show n) n

||| Fixture pair (TEST-DOCTRINE §2 / standards R10), runtime-constructed
||| and actually evaluated by the fixture tests below: the silence
||| fixture must NOT fire, the firing fixture MUST fire. Classification
||| goes through `classifyProvisionallyProven` with this pair — the
||| legacy `provisionalTest` constructor carries FixtureDebt and its
||| tests are not counted in any evidence ledger.
private
fixtures : FixtureObligation
fixtures = Fixtures (MkFixturePair
  (MkSilenceFixture (RuntimeConstructed "isExtension exampleChain (appendEntry exampleChain 44) in VeriSimTests.ProvenanceTests.testFixtureSilence") "a pure append preserves history, so the extension check must stay silent")
  (MkFiringFixture (RuntimeConstructed "isExtension exampleChain [11, 99, 33, 44] in VeriSimTests.ProvenanceTests.testFixtureFiring") "a rewritten history entry (the declared defect class) must fail the extension check"))

private
grade : TestId -> String -> IO TestResult -> ProvisionallyProvenTest
grade i d f = MkProvisionallyProvenTest
  (classifyProvisionallyProven i d provenTestsFrameworkProof (typeSafetyCert 6 "Dependent Types" "Idris2" ["VeriSimDB model invariants"]) fixtures) f

||| `new` extends `old` iff `old` is a prefix of `new` (append-only, modelled).
public export
isExtension : Chain -> Chain -> Bool
isExtension old new = take (length old) new == old

private
exampleChain : Chain
exampleChain = [11, 22, 33]

public export
testAppendGrowsByOne : ProvisionallyProvenTest
testAppendGrowsByOne =
  grade (tid 1) "Appending grows the chain by exactly one" (
    assertTrue (length (appendEntry exampleChain 44) == length exampleChain + 1)
      "A provenance append that rewrites history changes length unpredictably")

public export
testAppendPreservesPrefix : ProvisionallyProvenTest
testAppendPreservesPrefix =
  grade (tid 2) "Appending preserves the existing prefix" (
    assertTrue (take (length exampleChain) (appendEntry exampleChain 44) == exampleChain)
      "Append-only means history is a prefix of every later chain")

public export
testGenesisAppend : ProvisionallyProvenTest
testGenesisAppend =
  grade (tid 3) "The genesis chain accepts its first entry" (
    assertTrue (appendEntry [] 7 == [7])
      "An empty chain must be extendable, or no provenance can ever start")

public export
testFixtureSilence : ProvisionallyProvenTest
testFixtureSilence =
  grade (tid 4) "Fixture (silence): a pure append does not fire" (
    assertTrue (isExtension exampleChain (appendEntry exampleChain 44) == True)
      "A fire on clean input is a harness fault")

public export
testFixtureFiring : ProvisionallyProvenTest
testFixtureFiring =
  grade (tid 5) "Fixture (firing): a rewritten entry fires" (
    assertTrue (isExtension exampleChain [11, 99, 33, 44] == False)
      "Silence on a defective input is a payload fault")

public export
allProvenanceTests : List ProvisionallyProvenTest
allProvenanceTests = [testAppendGrowsByOne, testAppendPreservesPrefix, testGenesisAppend,
                      testFixtureSilence, testFixtureFiring]
