---
bump: patch
type: Fixed
---

- **Restore the weekly retrospective loop (#788).** Replaces the permanent, unclearable
`overrides.json` dismissal with an issue-closure lifecycle. A new reconciler
(`lib/pattern-state.sh`) migrates the overrides file to schema v2 and refreshes
every pattern's `filed`/`fixed`/`declined` state against the live state of its own
filed meta-issue on each run, so suppression lasts exactly as long as the fix it is
waiting on. `lib/compute-patterns.jq` now derives status through six ordered arms
(`dismissed` → `regressed` → `declined` → `filed` → `fixed` → `open`) with the
lifecycle record's `fixed_at` taking precedence over legacy audit rows, so a
pattern that recurs after its issue closed re-enters the eligible pool. Filing
carries back-pressure via three new config caps (`max_issues_per_run`,
`max_open_issues`, `max_open_per_category`), a `regressed` pattern bypasses the
occurrence threshold and the open-issues ceiling, `lib/meta-issue.sh` writes a
number-keyed lifecycle entry instead of a `dismissed` key, and `dismissed{}` is now
reserved for a maintainer's durable escape valve, written by no filing path. A
liveness warning fires when nothing is eligible while a pattern has occurred
at/above `min_occurrences` and is currently suppressed,
and the run report renders the whole pattern picture with each pattern's state,
filing outcome, and withholding cap. Migration happens on read, so consumer repos
get the same lifecycle with no manual step.

- **Give the filing decisions one executable owner (#788).** The cap decisions and the report fields they feed now live in
`lib/filing-decisions.sh`: the back-pressure cap arms and their order, the two
counts those arms compare against (both failing closed to an unestablished — never
zero — count), the `regressed` bypass of that open-issues ceiling (the occurrence-threshold
bypass stays in `lib/actionable-patterns.sh`), the liveness line the report renders, the won't-fix patterns
re-raised this run, and the per-pattern filing-outcome annotation. Each was
previously prose in the retrospective skill with no test, so a mis-ordered cap
check or a lost bypass would have shipped green.
