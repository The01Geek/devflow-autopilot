---
bump: patch
type: Added
---

- **Surface `claude-code-action` execution diagnostics on every cloud run.** The three
  cloud-tier workflows (`devflow-runner.yml`, `devflow-implement.yml`, `devflow.yml`) now run a
  post-`claude` `Surface execution diagnostics` step that passes the run's execution log to
  `scripts/surface-execution-diagnostics.sh` (shipped in #329), printing the run summary
  (`is_error`, `num_turns`, `duration_ms`, `total_cost_usd`, `permission_denials_count`) plus
  per-denial detail to the job log and the step summary. The step runs under `always()`, is
  read-only (no new token scope, no artifact upload, never changes a job's pass/fail), and is
  gated on the `devflow.execution_diagnostics_enabled` config key (default `true`) — set it to
  `false` for quieter runs. Maintainers debugging a stalled, incomplete, or unexpectedly-denied
  run now get the denial detail and run shape directly, the information that was irrecoverable
  for PR #325. (#337)
