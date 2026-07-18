---
bump: patch
---

Establish base-ref freshness before the synthesis floor selects commits (#532).

### Fixed

- `lib/efficiency-trace.sh --persist` now refreshes `origin/<base_branch>` into the
  remote-tracking cache (`refs/remotes/origin/<base_branch>`) **before**
  `synthesize_iter_workpads` selects any fix commit. A stale, never-refreshed
  `origin/<base>` — shared across linked worktrees — previously widened
  `origin/<base>..HEAD` back into already-merged foreign history, attributing another
  PR's fix commits to the current run (the synthesized-telemetry misattribution #532
  documents). When `origin` is configured but the refresh fails (offline, auth, or a
  contended `refs/remotes/origin/<base>.lock`), synthesis now **declines** — writing no
  record and emitting a `::warning::` naming the base ref as unestablished — rather than
  trusting a possibly-stale ref. Repos with no `origin`, and origins that carry no such
  branch, proceed against the local base with a breadcrumb (both recorded residual
  windows in `docs/efficiency-trace.md`). The base branch name now has a single producer
  in `lib/efficiency-trace.sh` (resolved once, consumed by both the refresh and
  `synth_base_ref`). The refresh advances no local branch ref. This is fix-forward only:
  existing misattributed records are left in place and are not distinguishable by record
  shape from records the fix produces (see the documented cutoff).
