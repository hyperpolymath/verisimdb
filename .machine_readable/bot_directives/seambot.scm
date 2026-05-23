;; SPDX-License-Identifier: MPL-2.0
(bot-directive
  (bot "seambot")
  (scope "integration health")
  (allow ("analysis" "contract checks" "docs updates" "integration runbooks"))
  (deny ("code changes without approval" "deleting database data or backups"))
  (notes "First status line must include: ACK: verisimdb cleanup cadence loaded. For integration maintenance, use daily stale-prune and weekly full clean cadence."))
