---
bump: patch
type: Fixed
---

- **`devflow-review.yml` auto-trigger hardening (workflow-resident half of #311).** The
  `preconditions_ok` crash arms now clear a crashed helper's captured stdout (`pre=""`) on
  both the no-retry path and the in-repo retry path, so a corrupted copy's partial output is
  never parsed (it fails closed to `unverifiable`). `devflow_review_run_count` now emits its own breadcrumb distinguishing a
  check-runs query failure from a non-numeric count. A repeated precondition deferral for the
  same head+reason now reuses/PATCHes the existing neutral `Devflow Review` check instead of
  posting a fresh completed-neutral check-run each time. The concurrency-group comment's
  worst-case wording was corrected (a same-instant race can double-review), and the dangling
  `docs/internal/workflows/review-rerun-checks.md` comment reference (plus the behind-base
  deferral summary) now points at the real `docs/workflow-triggers.md`. Adds coupled
  `lib/test/run.sh` static pins (CI-completion draft/stale-head guards, the missing-helper
  fail-open `return 0`, `resolve_pr_for_head`'s open-PR filter, and a `cancelled`-conclusion
  exclusion-filter fixture). The deferral-dedup reuse lookup now distinguishes a genuine
  check-runs query failure from an empty result with its own breadcrumb (consistent with the
  sibling helpers), and its jq projection is byte-coupled to the workflow source by a
  `run.sh` presence pin so a swapped column order can no longer pass green. (#325)
