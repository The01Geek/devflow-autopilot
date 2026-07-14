---
bump: patch
type: Added
---

- **Harness-side cost floor: cloud runs now record cost even when telemetry is dropped.** On both
  writable cloud workflows, the `--persist` backstop reads `claude-code-action`'s harness-written
  `execution_file` (via the new stdlib-only `scripts/extract-execution-cost.py` and the suite-drivable
  `scripts/prepare-harness-floor.sh`) and merge-fills its cost into the run's efficiency record as a
  distinct top-level `harness_cost` object — creating a minimal slug-bearing cost skeleton when a
  record-deriving run left no record at all. This is the first efficiency-pipeline floor NOT fed by an
  agent-volunteered operand, so the abnormal runs that drop telemetry — precisely the ones the
  retrospective and experiment analyses most need cost data for — now contribute a deterministic cost
  record. `harness_cost` is whole-job cost (segmentable by `workflow`/`command`, invisible to the
  per-phase `_run_cost`/`telemetry_complete` aggregates), and the telemetry-branch push-retry union is
  now merge-aware so a concurrent writer's `harness_cost` is never reverted. Best-effort and exit-0
  throughout; inert and byte-identical to before when the execution file is absent or the floor env is
  unset. (#475)
