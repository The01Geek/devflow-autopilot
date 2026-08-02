---
bump: patch
---

### Fixed

- Single-sourced the verification-flight scope that discharges the Phase 4.3
  completion-evidence gate. `.prflow/prompt-extensions/implement.md` carried two
  statements that disagreed — one excluding a focused result from the final gate, and a
  parenthetical admitting one — so two implement runs on the same tip read the same file
  and split, one completing on a focused-module flight and one dead-ending Blocked with
  its work finished. The rule now has one home: only a whole-suite result discharges that
  gate, and `skills/implement/phases/phase-4-documentation.md` and `CLAUDE.md`'s
  tiered-runner bullet point at that statement rather than restating it. Issue #1132.

### Added

- Granted `Bash(lib/test/run-shard.sh:*)` and `Bash(lib/test/shard-tally.py:*)` to
  `prflow_implement.allowed_tools` and `prflow.allowed_tools`, which makes the whole-suite
  requirement satisfiable on the cloud implement tier: when the tier's per-command
  execution ceiling terminates the parallel coordinator, a run now decomposes the same
  partition one shard at a time and recombines it — the way CI already satisfies the same
  required check — instead of downgrading its completion evidence. Phase 4.3 also gains a
  named `execution-ceiling` Blocked terminal, distinguishable in the workpad from a run
  that observed a failing suite.
