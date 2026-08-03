---
bump: patch
type: Added
---

- **Workflow-side stale-REJECT dismissal net.** Stale-REJECT dismissal used to run only as the reviewing agent's Phase 4.4 step, so a standalone `/prflow:review` that reached a verdict but never reached Phase 4.4 left the pull request wedged behind a superseded `CHANGES_REQUESTED` after a fresh APPROVE. `devflow.yml`'s `command` job now runs `scripts/dismiss-stale-rejections-net.sh` as a net for that gap, dismissing the stale REJECT **only when the verdict for the reviewed HEAD was positively determined as APPROVE** (gated on `derive-review-verdict.sh`'s `verdict_determined`, so a defaulted or API-degraded verdict never dismisses a live REJECT). It is idempotent and HEAD-scoped, so it never double-dismisses or fights the agent's unchanged Phase 4.4 dismissal. (#1175)
