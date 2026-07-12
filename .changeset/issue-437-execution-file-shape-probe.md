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
  with a re-runnable, evidence-backed probe (no longer an assertion asserted as settled fact). No
  runtime behavior changes — the helper is invoked only by the probe workflow and its tests. (#437)
