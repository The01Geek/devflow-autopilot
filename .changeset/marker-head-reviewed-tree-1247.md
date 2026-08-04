---
bump: patch
---

Fix: use the verdict marker's `head=` as the reviewed-tree comparand in the stale-REJECT dismisser and the Phase 0.3.6 blocker-recheck fast path

A pull-request review's reviews-API `commit_id` is not stable — GitHub can change it after the review is submitted, to a commit that did not exist at review time (observed on PR #1234). `scripts/dismiss-stale-rejections.sh` now reads the reviewed tree from the producer-emitted `prflow:review-verdict` marker's `head=` when the review carries one, falling back to `commit_id` only for a markerless review, so a genuinely-superseded REJECT whose `commit_id` GitHub advanced to the current head becomes dismissible again (and, inversely, a review whose marker head is the current head is no longer wrongly dismissed). The Phase 0.3.6 blocker-recheck fast path derives `$REJECTED_HEAD` the same way. `scripts/derive-review-verdict.sh` keeps failing closed on a head/`commit_id` disagreement by decision. The surrounding contract statements (docs, script headers, CLAUDE.md) are corrected to describe `commit_id` as mutable rather than authoritative, and the disagreement as ordinary GitHub behavior rather than a producer defect.
