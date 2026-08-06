---
bump: patch
type: Added
---

- **Gate the terminal `--status Complete` workpad write on a declared set of required run artifacts.** `scripts/workpad.py`'s `_terminal_complete_gate` now refuses to finalize a run as `Complete` unless the `## Progress` section carries a row for every member of a module-level `_REQUIRED_ARTIFACTS` set — initially the base-update checkpoint-4 record, satisfiable by either its clean `base-update-checkpoint-4` marker or the tier-refused variant, both marker spellings read. This makes the checkpoint-4 detector (`base_update_checkpoint4_present`) load-bearing: a run can no longer reach a published, `Complete` end state having silently skipped the base-update checkpoint. The refusal is a pure read that names the exact producing command; a resumed run cannot satisfy it on an inherited row (issue #1347's strip clears it). The now-superseded `--note` degrade fallback for checkpoint 4 is removed from `skills/implement/phases/phase-4-documentation.md` §4.3 so the gate has one recording format to read, and the three producer refusals (empty body, duplicate `## Progress`, marker anomaly) each name a specific remedy. (#1358)
