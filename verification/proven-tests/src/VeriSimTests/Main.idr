-- SPDX-License-Identifier: MPL-2.0
--
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <jonathan.jewell@open.ac.uk>
--
-- Entry point: aggregates VeriSimDB's proven-tests suites and exits
-- non-zero on any failure, so .github/workflows/proven-tests.yml can gate.

module VeriSimTests.Main

import ProvenTests.Types
import ProvenTests.Framework
import VeriSimTests.OctadTests
import VeriSimTests.DriftTests
import VeriSimTests.ProvenanceTests
import System

%default total

allSuiteTests : List ProvisionallyProvenTest
allSuiteTests = allOctadTests ++ allDriftTests ++ allProvenanceTests

suite : TestSuite
suite = MkTestSuite "VeriSimDB model invariants" (map toRunnable allSuiteTests)

isPass : TestResult -> Bool
isPass Passed = True
isPass _ = False

printOutcome : (TestMetadata, TestResult) -> IO ()
printOutcome (meta, result) =
  putStrLn $ "  [" ++ show (statusOf meta.provenance) ++ "] "
          ++ meta.test_id.test_name ++ ": " ++ show result

main : IO ()
main = do
  putStrLn "=== verisimdb-proven-tests: model invariant suites ==="
  results <- runSuite suite
  traverse_ printOutcome results
  let passed = length (filter (isPass . snd) results)
  putStrLn $ "=== " ++ show passed ++ "/" ++ show (length results) ++ " passed ==="
  if passed == length results
     then putStrLn "SUITE: PASS"
     else do putStrLn "SUITE: FAIL"
             exitFailure
