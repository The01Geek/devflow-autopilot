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
  rationale, so every mid-run retag is a recorded, retrospective-auditable claim. The guard
  resolves the row each pair targets with the rewriter's own lookup, so a text tweak on an
  already-`(post-merge)` criterion creates no new deferral and needs no note — even when the
  `OLD` substring does not itself span the tag. The multi-pair backstop snapshots each
  criterion's `(post-merge)` state across every tick state and compares it positionally,
  so a crafted `--rewrite-ac` sequence cannot launder a note-less retag — not onto an
  already-ticked criterion, and not by removing the tag from one criterion while adding it
  to another (which nets to zero under an aggregate count). A `--rewrite-ac` NEW containing
  a line break is now rejected structurally: it would split one criterion into two rows,
  injecting an unreviewed row and defeating both guards. The `--replace-acs-file` channel
  remains a documented exception. (#340)
