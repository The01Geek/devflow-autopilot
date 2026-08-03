---
bump: patch
type: Changed
---

- **Raise the implement tier's per-command Bash ceiling so the parallel verification coordinator can run to a verdict.** `devflow-implement.yml`'s `Run Claude Code` step now sets a deliberately bounded `BASH_MAX_TIMEOUT_MS` of 20 minutes (via the `settings` input's `env` object), above Claude Code's 600000 ms default. Previously the parallel coordinator (`lib/test/run-parallel.sh`) was killed at 10 minutes on the 4 vCPU runner before printing anything, wasting ~28% of measured run wall-clock before the same work was redone shard by shard. The `#1132` shard-decomposition path stays the in-run fallback. The "not escapable in-run" prose in `.prflow/prompt-extensions/implement.md`, `docs/implement-skill.md`, and `CLAUDE.md` is scoped to the run and now names `devflow-implement.yml` as where the ceiling is set. (#1179)
