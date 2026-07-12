---
bump: patch
type: Added
---

- **Pinned what the harness actually reports about its execution file — and the answer overturns a
  long-standing assumption.** Added `scripts/extract-execution-shape.sh`, a best-effort read-only
  helper that reads a `claude-code-action` execution file and emits a **redacted** shape record —
  per-field `present`/`absent`/`unavailable` for token `usage`, wall-clock timing, `tool_use`,
  `subagent_type`, and `permission_denials`, plus the top-level encoding (array/object/jsonl) —
  dropping every string *value* leaf so no prompt text, repository content, or attacker-controlled
  check-run name can leave a run. Two repo-internal probe jobs in `matcher-probe.yml`
  (`execfile-shape-probe`, `hook-probe`) feed a real cloud run's execution file through it and probe
  whether a base-branch `Stop` hook fires under `claude-code-action`.
- **Observed result (cloud tier): every field is present.** The `execfile-shape-probe` ran and its
  artifact records `encoding: array` with per-message token `usage`, wall-clock
  (`duration_ms` / `duration_api_ms` / `ttft_ms`), `tool_use` events, `subagent_type` on `Task`
  dispatches, and `permission_denials` all **present** — plus cost directly (`costUSD`,
  `total_cost_usd`, per-model `modelUsage`). Recorded in the new `docs/execution-file-shape.md`.
- **Observed result (local tier): the transcript's token counts are real.** Added
  `scripts/stop-hook-probe.sh`, registered as a `Stop` hook in this repo's `.claude/settings.json`,
  which writes a gitignored breadcrumb recording (a) that the hook fired — the measurement the
  `hook-probe` job reads to settle whether `.claude/` hooks execute under `claude-code-action` at
  all — and (b) a four-way `real`/`placeholder`/`absent`/`unavailable` verdict on whether the `Stop`
  payload's `transcript_path` JSONL carries genuine per-message token counts. Observed: **`real`**
  (196 `usage` blocks, largest figure 342,272) — not the streaming placeholders it was assumed to
  hold.
- **Consequence: the "cost half is unreconstructable" claim in `docs/efficiency-trace.md` was false,
  and is corrected.** Both tiers demonstrably carry the tokens, wall-clock, and subagent dispatch
  roster with **zero agent cooperation**, so an agent-independent telemetry floor is buildable. The
  honest form — now the shipped wording — is that no backstop DevFlow *ships* reconstructs it: a gap
  in what was built, not a limit of the platform. Two things stay open and are stated as such: the
  `execution_file` schema is not a public contract (the record is a dated observation of one action
  version — re-dispatch after upgrades), and realness is not freshness (the transcript may lag, so a
  `Stop`-time read can miss the final turn).
- **Scope of runtime change.** No consumer-facing, engine, review-loop, or merge-gate surface is
  touched, and `extract-execution-shape.sh` is invoked only by the probe workflow and its tests. The
  one behavior change is repo-internal: this repo's own `.claude/settings.json` gains a third,
  best-effort `Stop` hook (always exit 0, silent on stdout, writes only under `.devflow/tmp/`), and
  `.claude/` is not shipped to consumers. (#437)
