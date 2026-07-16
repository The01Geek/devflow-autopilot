---
bump: minor
type: Added
---

- **Weekly retrospective report gains a "Recurring intervention targets" section.** Across the
  accumulated `retrospectives.jsonl`, the loop now groups every entry's
  `suggested_interventions[].candidate_targets[]` by exact target path and lists each target
  named in ≥2 distinct PRs — with its distinct-PR count, contributing PR numbers, and a
  representative intervention summary — sorted by descending PR count. The section is
  report-only: it files no issue and writes no dismissal state, so it surfaces recurring
  targets regardless of whether the underlying PRs' coarse category is dismissed in
  `overrides.json`. New helper `lib/recurring-targets.sh` (backed by `lib/recurring-targets.jq`)
  reads the existing field — no new persisted store. (#523)
