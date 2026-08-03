---
bump: patch
type: Added
---

- **Tell the implement run how to terminate a process it launched — by the recorded identifier, never by a command-line pattern.** `skills/implement/SKILL.md`'s always-resident section now carries a general rule (terminate by the identifier recorded at launch; never `pgrep`/`pkill`-style name matching, which cannot distinguish an unrelated process on the same host and cannot be attributed afterwards), including the no-recorded-identifier and single-stale-process arms, and `.prflow/prompt-extensions/implement.md` gains the PRFlow instantiation (the `.claude/worktrees/` sibling-checkout concurrency hazard, the parallel-suite run-root PID mechanism, and the `ps`-cross-checked stale-coordinator remedy). (#1202)
