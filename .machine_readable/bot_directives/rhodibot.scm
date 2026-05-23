;; SPDX-License-Identifier: MPL-2.0
(bot-directive
  (bot "rhodibot")
  (scope "rsr-compliance")
  (allow ("metadata" "docs" "repo-structure checks" "policy validation"))
  (deny ("destructive edits without approval" "deleting database data or backups"))
  (notes "First status line must include: ACK: verisimdb cleanup cadence loaded. Verify policy states: daily stale-prune (>14 days), weekly full clean, never touch persistent data without explicit approval."))
