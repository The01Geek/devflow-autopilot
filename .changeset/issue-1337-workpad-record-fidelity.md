---
bump: patch
type: Fixed
---

- **Workpad record fidelity.** `workpad.py update` now suppresses a `--note` bullet whose
  text byte-equals a `--checkpoint` text requested in the same invocation, so the Phase 1
  cloud hydration event renders as a single marker-carrying `## Progress` row instead of a
  duplicated pair. A terminal `--status Complete` write now deterministically ticks every
  still-unticked top-level `## Progress` phase row (sourced from `_PROGRESS_PHASES`), a
  backstop for the cooperative per-phase ticks that were observed silently not landing;
  `Failed`/`Cancelled`/`Blocked` and the interim statuses tick nothing. Newly-produced
  workpad display text finishes the `prflow` rename — `new-body` seeds `/prflow:implement
  run started` and renders the `# PRFlow Workpad` H1 — while the machine-consumed
  `## Devflow Reflection` heading stays frozen. `branch-for-issue.py` deletes apostrophes
  (U+0027 and U+2019) before the slug substitution, so a possessive contributes a clean
  token rather than a stray `-s-` fragment. (#1340)
