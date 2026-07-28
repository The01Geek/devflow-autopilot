---
bump: patch
type: Changed
---

- **Split the required `lib + python tests` CI check into a concurrent job matrix**
  (issue #877). The single sequential test job is replaced by four `shard` jobs —
  `monolith` (`lib/test/run.sh` with the module tier suppressed via the new
  `DEVFLOW_SKIP_SUITE_MODULES` selector) plus three `modules-*` groups whose union is
  exactly the registered module set — and an aggregator job that **keeps the required
  status-check name `lib + python tests` verbatim**, since that name is the
  branch-protection contract and renaming it would silently un-gate merges. The new
  `lib/test/run-shard.sh` dispatches a shard to its runners and writes a per-shard
  tally; the new `lib/test/shard-tally.py` extracts and recombines those tallies into
  the existing aggregate accounting. The aggregator runs under `if: always()` and fails
  closed when any shard failed, was cancelled, or was skipped — a skipped required check
  that auto-passes being the classic un-gating trap — and the recombination preserves the
  full skip population rather than laundering it into a clean pass (issue #456). No test
  is dropped: `lib/test/run.sh` asserts the shard map's module union against the
  registry — and, in both directions, that the registry equals the module set the suite
  actually drives and that no module is listed in two shard groups. The recombination's
  skip-accounting guard is unconditional: a tally announcing `0 skipped` beside a
  non-empty skip detail file fails closed instead of dropping those lines, `--expect` is
  required so the missing-shard guard cannot be disabled by omission, and the
  aggregator's shard-result gate moved out of inline workflow YAML into
  `lib/test/gate-shard-result.sh` so every arm (success / failure / cancelled / skipped /
  unestablished) is driven by the suite. Measured on this PR's own CI: the four shards ran 639s / 291s / 54s / 43s
  with a 9s aggregator, for a ~665s wall clock against a ~850s single-job baseline
  (a past-time snapshot, not a pinned figure). Reaching the sub-4-minute target needs
  further work — the `monolith` shard still carries the pin-corpus block through the
  pooled real-runner meta-test, and that block's fixture cost is tracked separately.
