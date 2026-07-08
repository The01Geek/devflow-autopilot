---
bump: patch
type: Fixed
---

- **Collapse duplicate workflow runs to the latest per `(workflow_id, event)` group in the review CI-green gate.** `scripts/derive-review-preconditions.sh` now collapses the non-self Actions runs on a PR head to the highest-`run_number` run per `(workflow_id, event)` group before gating, so a superseded non-green run — an approval-gated re-dispatch, a rapid double-fire, or a cancelled sibling — no longer wedges `Devflow Review` behind a permanently-deferred required check once a newer run of the same workflow+event has passed. A non-self run missing a numeric `workflow_id`/`run_number` fails closed as `unverifiable` (never a dropped signal), and a run still awaiting manual approval (conclusion `action_required`) defers with a new, distinct `ci-approval-required` reason so the neutral check can say so in plain language. (#352)
