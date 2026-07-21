---
bump: patch
---

### Added

- Cloud per-agent reasoning-effort **applied arm** (issue #669), gated on the `SEAM_PROVEN`
  verdict from the `agents-seam-probe.yml` spike. On the cloud tier the pre-launch `cargs`
  component now composes each capability-gated per-agent effort into the process-start
  `--agents` agent-definition (`resolve-review-overrides.py --known-roster
  --applied-agents-json`), so a configured per-agent effort takes effect instead of the
  honest fallback. Haiku-model and `effort_supported:false` agents are stripped and keep
  reporting `session-fallback`.
- Single source of truth for the applied telemetry via an explicit applier→recorder sidecar
  (`--applied-sidecar-json` → `.devflow/tmp/agent-effort-applied.json`): `lib/efficiency-trace.jq`
  reads it to record `effective` and `application_point: agent-definition`. Absent the sidecar
  value the engine records `effective: null` and never `agent-definition` (unknown is not
  zero). The applied `effective` is a spike-grounded proxy, not a per-run measurement.
