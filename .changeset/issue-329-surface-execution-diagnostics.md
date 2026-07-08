---
bump: patch
type: Added
---

- **Surface claude-code-action execution diagnostics via a shared helper.** New best-effort
  `scripts/surface-execution-diagnostics.sh` reads a claude-code-action execution log and prints
  the run summary (`is_error`, `num_turns`, `duration_ms`, `total_cost_usd`,
  `permission_denials_count`) plus permission-denial detail (count always; per-denial `tool_name`
  and truncated `tool_input` when the log carries it) to stdout, and appends the same block to
  `$GITHUB_STEP_SUMMARY` when set. It mirrors `parse-engine-error.sh`'s slurp-based
  array/object/JSONL traversal and `lib/resolve-jq.sh` / `DEVFLOW_JQ` seam, degrades to an explicit
  "no diagnostics available" line on an absent/empty/unparseable file (or one carrying neither a
  result event nor denial detail), and always exits
  0 so it never fails the calling step. A new `devflow.execution_diagnostics_enabled` config key
  (boolean, default `true`) is added to the schema and example config to gate the surfacing. The
  three workflow-step call sites land in a follow-up (the DevFlow bot token lacks the
  `workflows`-scoped push). (#329)
