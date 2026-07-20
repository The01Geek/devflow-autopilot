---
bump: patch
---

### Added

- Per-agent effort observability in the per-run efficiency telemetry (issue #609, carried from
  #554; PR #630): the per-run record now carries an `agent_effort[]` block per iteration —
  agent id plus exactly `requested`, `resolved`, `application_point`, `effective` (null unless
  read back), and `fallback_reason` — populated over the full dispatched roster
  (`phase3_dispatched` ∪ the new `dispatched_effort` iter-workpad field, which captures the
  Phase-1/1.5/2 checklist-agent dispatches with their effort decisions). A
  `checklist-generator.effort` override is no longer silently missing from the record, and a
  dispatched agent with no override records an all-null `session-inheritance` block.
  `resolve-review-overrides.py` gains an `--effort-json` mode emitting the five-field map per
  dispatched agent. Additive and nullable — no `schema_version` bump, and
  `validate-telemetry-artifact.sh` passes the block unchanged.
