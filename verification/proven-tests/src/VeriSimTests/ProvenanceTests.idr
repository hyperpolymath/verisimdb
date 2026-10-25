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

private
exampleChain : Chain
exampleChain = [11, 22, 33]

public export
testAppendGrowsByOne : ProvisionallyProvenTest
testAppendGrowsByOne =
  provisionalTest (tid 1) "Appending grows the chain by exactly one" (
    assertTrue (length (appendEntry exampleChain 44) == length exampleChain + 1)
      "A provenance append that rewrites history changes length unpredictably")

public export
testAppendPreservesPrefix : ProvisionallyProvenTest
testAppendPreservesPrefix =
  provisionalTest (tid 2) "Appending preserves the existing prefix" (
    assertTrue (take (length exampleChain) (appendEntry exampleChain 44) == exampleChain)
      "Append-only means history is a prefix of every later chain")

public export
testGenesisAppend : ProvisionallyProvenTest
testGenesisAppend =
  provisionalTest (tid 3) "The genesis chain accepts its first entry" (
    assertTrue (appendEntry [] 7 == [7])
      "An empty chain must be extendable, or no provenance can ever start")

public export
allProvenanceTests : List ProvisionallyProvenTest
allProvenanceTests = [testAppendGrowsByOne, testAppendPreservesPrefix, testGenesisAppend]
