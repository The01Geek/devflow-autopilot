---
bump: patch
type: Changed
---

- **Reproduce-first gate classifies bug reports from issue content, not the `bug` label.** `/devflow:implement`'s Phase 2.1.5 reproduce-first gate now fires on a content classification recorded in Phase 1.1/1.3 (bug-report vs. non-bug, from the issue title and body, with the `bug` label as one input signal) instead of the label alone — so a genuine bug filed without the label still gets reproduction-first protection, and a mislabelled feature request no longer dead-ends at Blocked. Content overrides the label on a positive classification in both directions; ambiguous content defaults to the label when present, else to non-bug. The classification is recorded as a superseding `classification: ` workpad note (exactly one at all times), and `workpad.py update` gains idempotent `--record-classification` / `--reconcile-reproduction` capabilities that Phase 1.3 runs on every entry to reconcile the label-based skeleton (still pre-rendered deterministically by the cloud `gate` job and `new-body`) to the recorded classification. Consumer repos that don't label bug reports `bug` are the primary beneficiaries. (#449)
