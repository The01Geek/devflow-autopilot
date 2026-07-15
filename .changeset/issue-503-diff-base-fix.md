---
bump: patch
type: Fixed
---

- **Review engine's local-diff base now tracks the PR's own base ref, not the stale run-start SHA.** The Phase 0.2 head-override diff and the `/devflow:review-and-fix` Step 3 item 6a stale-prose pre-check pinned their diff base to the run-start `baseRefOid` (`$PR_BASE_SHA`), so an in-loop Checkpoint-3 base merge attributed base content to the PR as added — spurious `STALE` findings, false `REJECT`s, and a fail-open where an empty cached diff read as clean `APPROVE`. Both now diff against the fetched tip of `origin/<baseRefName>` in PR mode and the configured `base_branch` in current-branch mode (fail-closed to `main`), mirroring `update-branch-checkpoint.sh`'s explicit-refspec fetch and one-shot `--unshallow` retry, with a deleted-base fallback to the stored `baseRefOid`. The head-override producer checks the raw diff, filtered candidate, promotion write, and stdout publication; any failure removes every candidate and prior cache, surfaces a Blocked outcome, and can never become an `APPROVE`-eligible empty diff. A retargeted PR whose base ref ≠ `base_branch` records the divergence as an observable residual. (#503)
