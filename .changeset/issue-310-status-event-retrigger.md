---
bump: patch
type: Added
---

- **`devflow-review.yml` now auto-recovers a deferred review on legacy commit-status-only CI.** A new `status` trigger lets a repo whose CI reports only via the commit-status API (classic Jenkins, legacy CircleCI) re-fire a review that was deferred behind `require_ci_green` once its CI turns green — with no manual Re-run. The precheck filters to `state == 'success'` (the cheap green-state filter, mirroring the `workflow_run` push filter) before a runner spins, so non-success states never spin the route; the CI-completion route branch gains a `status` arm that resolves the PR from the status head SHA (the payload carries no PR reference) and reuses the existing open-state/draft/stale-head/exactly-once/precondition machinery. It cannot self-trigger because the workflow posts check-runs, never commit statuses. (#335)
