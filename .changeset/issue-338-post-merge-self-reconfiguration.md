---
bump: patch
type: Changed
---

- **Tightened the `/devflow:implement` `(post-merge)` contract.** Phase 3.4 now names a
  third forbidden deferral case — **self-reconfiguration verification** (a criterion whose
  only unmet precondition is the orchestrator's own session/harness/account being in the
  configuration the diff just shipped, e.g. a hook it just registered or a flag it just
  enabled): the host *can* become a fresh session with the change active, so it is runnable
  pre-merge and is run-and-evidenced (or Blocked), never `(post-merge)`. A matching red flag
  and the closing retag paragraph refuse it alongside the tooling-gap and self-claim cases,
  and Phase 2.3.4 and Phase 1.2 bind to the same rule. `scripts/workpad.py` now structurally
  rejects a `--rewrite-ac` that appends the `(post-merge)` tag without a non-empty `--note`
  rationale, so every mid-run retag is a recorded, retrospective-auditable claim. (#340)
