---
bump: patch
---

### Added

- Single source of truth for cloud per-agent reasoning-effort telemetry (issue #669) via an
  explicit applier→recorder sidecar (`resolve-review-overrides.py --applied-sidecar-json` →
  `.devflow/tmp/agent-effort-applied.json`): `lib/efficiency-trace.jq` reads it to record
  `effective` and `application_point: agent-definition`. Absent the sidecar value — or on any
  malformed sidecar — the engine records `effective: null` and never `agent-definition`
  (unknown is not zero). The sidecar read fails closed on every shape: a non-object top level,
  a per-agent value that is not a valid effort enum string (including a valid-falsy `""` or
  `0`), trailing garbage after a valid JSON prefix, and a multi-document file all yield no
  applied entry and leave the telemetry record intact. The applied `effective` is a
  spike-grounded proxy, not a per-run measurement.
- The pre-launch `applied_effort` composer step (`scripts/compose-applied-effort.sh`, wired
  into all three cloud workflows) that composes each capability-gated per-agent effort into
  the process-start `--agents` agent-definition. Haiku-model and `effort_supported:false`
  agents are stripped and keep reporting `session-fallback`.

  **The application half is deferred and ships gated OFF.** The composer short-circuits
  unless `DEVFLOW_AE_APPLY=1`, which no workflow sets, so no configured per-agent effort is
  applied on any tier yet and the honest `session-fallback` stands. The `agents-seam-probe.yml`
  spike recorded `SEAM_PROVEN` for a **fully-defined new agent** (`description` + `prompt` +
  `effort`); this composer emits an **effort-only** entry keyed by an **already-installed**
  plugin agent id, and nothing measured establishes that such an entry patches the installed
  agent rather than shadowing it. Arming it before that shape is probed risks degrading every
  merge-gating review agent to a prompt-less stub, so it waits for a probe row.

### Security

- The read-only review tier composes per-agent effort from the **trusted base-ref config**,
  never the PR-head working tree, so a PR author cannot lower the merge-gating reviewer's
  reasoning effort on their own PR. The composer threads the base-ref config (materialized by
  `baseprovision`) as `--config`, mirroring the sibling provider/effort steps; a missing
  materialized file fails closed to the honest fallback. An explicit-empty `EFFORT_SUPPORTED`
  no longer coerces to `true` (fails closed), and the applier's sidecar default path is
  repo-root-anchored to match the recorder regardless of cwd. (These protect the composer
  path, which is inert by default per the deferral above.)
