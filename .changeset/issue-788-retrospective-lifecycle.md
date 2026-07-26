---
bump: patch
---

Restore the weekly retrospective loop with an issue-closure lifecycle (#788, PR #842).

`.devflow/learnings/overrides.json` moves to `schema_version: 2` with two maps: a
machine-owned `patterns{}` lifecycle map and a human-owned `dismissed{}` escape valve.
The new `lib/pattern-state.sh` reconciler migrates a v1 file in place and, each run,
reconciles every filed meta-issue against live GitHub state — a meta-issue closed
COMPLETED makes its pattern `fixed`, closed NOT_PLANNED/DUPLICATE makes it `declined`
(each stamped with `closedAt` as `fixed_at`), an open one stays `filed`. `lib/meta-issue.sh`
now appends a `filed` lifecycle record (keyed by issue number) instead of writing a
permanent `dismissed` entry, so a suppression lasts only as long as the fix it waits on:
once an occurrence merges after `fixed_at`, the pattern reports `regressed` and re-enters
the eligible pool. `lib/compute-patterns.jq` gains the `declined` and `filed` status arms
(order: dismissed → regressed → declined → filed → fixed → open) with lifecycle-record
`fixed_at` precedence over legacy audit rows. Filing now carries back-pressure via three
new `devflow_retrospective` config keys — `max_issues_per_run` (3), `max_open_issues` (10,
bypassed by a regressed pattern), and `max_open_per_category` (2) — and the weekly report
renders every withheld pattern with its cap, re-filed won't-fix patterns, and a liveness
warning when nothing is eligible while a recurring pattern sits suppressed.
