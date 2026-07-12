---
bump: patch
type: Added
---

- **Pin what the harness actually reports about its execution file.** Added
  `scripts/extract-execution-shape.sh`, a best-effort read-only helper that reads a
  `claude-code-action` execution file and emits a **redacted** shape record — per-field
  `present`/`absent`/`unavailable` for token `usage`, wall-clock timing, `tool_use`,
  `subagent_type`, and `permission_denials`, plus the top-level encoding (array/object/jsonl)
  — dropping every string leaf so no prompt text, repository content, or attacker-controlled
  check-run name can leave a run. Repo-internal probe jobs in `matcher-probe.yml` feed a real
  cloud run's execution file through it (and probe whether a base-branch `Stop` hook fires under
  `claude-code-action`); their observed result — currently pending first dispatch, recorded honestly
  as `unavailable` per field — lands in `docs/execution-file-shape.md`, replacing
  the previously-unproven
  "the token/wall-clock cost half is unreconstructable" assertion in `docs/efficiency-trace.md`
  with a re-runnable, evidence-backed probe (no longer an assertion asserted as settled fact).
- **Measured the local transcript's token shape, and it refutes the old claim.** Added
  `scripts/stop-hook-probe.sh`, registered as a `Stop` hook in this repo's `.claude/settings.json`,
  which writes a gitignored breadcrumb recording (a) that the hook fired — the measurement the
  `hook-probe` job reads to settle whether `.claude/` hooks execute under `claude-code-action` at
  all — and (b) a four-way `real`/`placeholder`/`absent`/`unavailable` verdict on whether the
  `Stop` payload's `transcript_path` JSONL carries genuine per-message token counts. Observed on the
  local tier: **`real`** (196 `usage` blocks, largest figure 342,272), so the long-standing
  "the token/wall-clock cost half is unreconstructable" assertion is false as stated — the honest
  form is that no backstop DevFlow *ships* reconstructs it. The cloud tier remains pending first
  probe dispatch.
- **Scope of runtime change.** No consumer-facing, engine, review-loop, or merge-gate surface is
  touched, and `extract-execution-shape.sh` is invoked only by the probe workflow and its tests. The
  one behavior change is repo-internal: this repo's own `.claude/settings.json` gains a third,
  best-effort `Stop` hook (always exit 0, silent on stdout, writes only under `.devflow/tmp/`), and
  `.claude/` is not shipped to consumers. (#437)
