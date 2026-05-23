;; SPDX-License-Identifier: MPL-2.0
;; .bot_directives — verisimdb repo-specific bot rules
;; Media-Type: application/vnd.bot-directives+scm

(bot-directives
  (version "1.1")
  (notes
    "Repo-specific constraints for verisimdb."
    "All bots must acknowledge policy in their first status line: ACK: verisimdb cleanup cadence loaded."
    "Maintenance cadence for build artefacts: daily stale-prune (older than 14 days), weekly full build clean."
    "Never delete or mutate real database data, backups, or user datasets without explicit human approval."))
