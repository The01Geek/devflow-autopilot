---
bump: patch
---

### Added

- Cloud per-agent reasoning-effort **applied arm** (issue #669), gated on the `SEAM_PROVEN`
  verdict from the `agents-seam-probe.yml` spike. On the cloud tier the pre-launch `applied_effort`
  composer step now composes each capability-gated per-agent effort into the process-start
  `--agents` agent-definition (`resolve-review-overrides.py --known-roster
  --applied-agents-json`), so a configured per-agent effort takes effect instead of the
  honest fallback. Haiku-model and `effort_supported:false` agents are stripped and keep
  reporting `session-fallback`.
- Single source of truth for the applied telemetry via an explicit applier→recorder sidecar
  (`--applied-sidecar-json` → `.devflow/tmp/agent-effort-applied.json`): `lib/efficiency-trace.jq`
  reads it to record `effective` and `application_point: agent-definition`. Absent the sidecar
  value the engine records `effective: null` and never `agent-definition` (unknown is not
  zero). The applied `effective` is a spike-grounded proxy, not a per-run measurement.

### Security

- The read-only review tier now composes per-agent effort from the **trusted base-ref
  config**, never the PR-head working tree: a PR author can no longer lower the merge-gating
  reviewer's reasoning effort on their own PR. The composer threads the base-ref config
  (materialized by `baseprovision`) as `--config`, mirroring the sibling provider/effort
  steps; a missing materialized file fails closed to the honest fallback. An explicit-empty
  `EFFORT_SUPPORTED` no longer coerces to `true` (fails closed), and the applier's sidecar
  default path is repo-root-anchored to match the recorder regardless of cwd.
