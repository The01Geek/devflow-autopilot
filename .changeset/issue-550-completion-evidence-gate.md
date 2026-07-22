---
bump: patch
type: Added
---

- **Gate receiving-review completion claims on a producer-owned completion-evidence check.** A new
  thin, deterministic validator (`scripts/check-completion-evidence.py`, python3 stdlib-only,
  repo-agnostic) validates a receiving-code-review completion claim against current, producer-owned
  evidence — the durable verification record, the candidate-identity and findings anchors, the
  disposition ledger, and deferral traces — and prints exactly one `completion-check: <token> — <detail>`
  verdict line (one of eight tokens: `pass`, `missing-evidence`, `stale-candidate`,
  `verification-not-pass`, `skipped-checks-present`, `undischarged-findings`, `non-durable-deferral`,
  `unverifiable-trace`). The `receiving-code-review` Verification Gate gains a fifth evidence item
  that runs the check and quotes its verdict verbatim (phrasing "complete" only on a quoted `pass`,
  and `degraded: unvalidated (<reason>)` when the check produces no verdict line); the
  `review-and-fix` loop discharges the item at Loop Exit over its run-scoped records, refreshing the
  verification record on an identity-keyed mismatch and carrying any non-pass token into its final
  verdict line. The loop's run-scoped `deferrals.json` declares its durable channel once at manifest
  level (`default_channel: "loop-record"`) and the check resolves a channel-less entry from that
  declaration, so an ordinary loop run with surviving deferrals reports `pass` instead of a spurious
  `non-durable-deferral`; a declaration outside the four durable channels is discarded, and a
  per-entry `channel` still wins. (#550)
