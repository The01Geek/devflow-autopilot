---
bump: patch
type: Fixed
---

- **A permission-denial record is no longer discarded when the run produced no usable
  cost figures.** Denial forensics ride the per-run efficiency record as its
  `permission_denials` key, and `apply_denial_floor` could only ever *merge* onto a host
  record — so a run that died before yielding cost figures lost its fully-built denial
  record entirely. `scripts/prepare-harness-floor.sh` refuses to stage an all-null
  `harness_cost`, which empties the cost handoff, which returns `apply_harness_floor`
  before its own skeleton arm, so no host record existed to merge onto and the denial
  record was dropped with only an expiring job-log warning — precisely the stall / crash /
  execution-ceiling class where denial forensics matter most. The denial floor now has a
  skeleton arm mirroring the cost floor's (same run-id targeting, same overwrite guard,
  same minimal `synthesized: true, source: null` shape), so the record is written rather
  than declined. An unjoinable denial record still beats a vanished one. This **closes the
  all-null-cost drop path**; it is not an unconditional guarantee — the mirrored skeleton
  inherits the cost skeleton's two gates, and each remains a named, breadcrumbed drop
  path: a `pr-description` or unclassified command class, and an unresolvable PR number
  (the record has no slug to be keyed by). How often either is reached is unestablished.
- **The PR number is now resolved even when the cost is inert.**
  `scripts/prepare-harness-floor.sh` short-circuited its PR resolution on every
  cost-inert branch, back when `DEVFLOW_EXECUTION_PR` was the cost floor's operand alone.
  It has a second consumer now, and the two operands fail independently — so the
  short-circuit made the denial skeleton unreachable on exactly the path it exists for.
  The cost side is unchanged: `apply_harness_floor` still returns at its first guard on an
  empty cost, so no all-null `harness_cost` and no cost skeleton is ever staged.
- **`efficiency_telemetry_enabled` now documents that it also gates denial forensics.**
  Its schema description and the `docs/efficiency-trace.md` config table mentioned only
  trace rendering and record writes, so a consumer disabling it for cost had nothing
  warning them that they were also giving up the durable record of what the harness
  refused.
