;; SPDX-License-Identifier: MPL-2.0
(bot-directive
  (bot "echidnabot")
  (scope "formal verification and fuzzing")
  (allow ("analysis" "fuzzing" "proof checks"))
  (deny ("write to core modules" "write to bindings" "deleting database data or backups"))
  (notes "First status line must include: ACK: verisimdb cleanup cadence loaded. If maintenance tasks are requested, follow cadence: daily stale-prune (>14 days), weekly full build clean."))
