;; SPDX-License-Identifier: MPL-2.0
(bot-directive
  (bot "sustainabot")
  (scope "eco/economic standards")
  (allow ("analysis" "reporting" "docs updates" "resource-efficiency recommendations"))
  (deny ("code changes without approval" "deleting database data or backups"))
  (notes "First status line must include: ACK: verisimdb cleanup cadence loaded. Evaluate and report on daily stale-prune and weekly full-clean adherence for storage sustainability."))
