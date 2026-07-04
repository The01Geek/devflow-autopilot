---
bump: patch
type: Added
---

- **Gate the Devflow Review auto-trigger on branch-freshness and other-CI-green
  preconditions.** Two new config keys under `devflow_review` — `require_up_to_date` and
  `require_ci_green`, both defaulting to enabled — defer the LLM review while the PR branch
  is behind its configured `base_branch` or while any other CI signal on the head (Actions
  workflow runs excluding the review workflow itself, legacy commit statuses, external check
  runs — no job names referenced) is pending or red. A deferral still posts the required
  `Devflow Review` check, concluded `neutral` with a "waiting: branch behind base" /
  "waiting: other CI not green" reason, so the required context is never absent; the review
  then auto-re-triggers on branch update (`synchronize`), Actions CI completion
  (`workflow_run: completed` — consumer repos name their CI workflows in the trigger list, a
  GitHub platform requirement), or external CI completion (`check_suite: completed`).
  Preconditions are evaluated fail-closed by the new
  `scripts/derive-review-preconditions.sh`; a repo with no other CI is reviewed immediately
  and never wedged, and setting either key to `false` restores the unconditional trigger.
  (#307)
- **`/devflow:create-issue` now steelmans its own draft before presenting it.** A new
  mandatory Step 3.5 stress-tests every load-bearing claim, file reference, and acceptance
  criterion of the assembled draft against the actual code with targeted reads/greps,
  hunting for missed acceptance criteria, edge cases, wrong assumptions, and unstated scope
  — then revises the draft and re-runs the no-options gate before the user sees it. (#307)
