---
bump: patch
---

### Changed

- `/prflow:docs-verify --report-only` is now a docs-first **code explorer** rather than a
  documentation auditor. Its deliverable is a map of how the topic works in the code today;
  internal documentation is its entry point and a source of provisional evidence, not its
  subject. Documentation drift is still reported, briefly, as an observation rather than as
  the pass's purpose. Write mode is unchanged.
- A doc-derived claim now has three explicit fates instead of being silently promoted to
  fact: confirmed against the implementing code (a finding), contradicted by it (drift), or
  returned marked `doc-sourced, unconfirmed`.
- The report-only pass ships a **brownfield disposition** — assume non-obvious coupling,
  treat a surface-level read as unfinished — with the breadth/depth relationship stated
  explicitly so it does not read as contradicting the duty floor: the floor bounds how many
  things are examined, never how carefully.
- Report-only output now cites `file:line`, marks which files are **essential**, and
  calibrates quantitative claims (`(unverified estimate)` for any count not read from tool
  output in the session) — techniques adopted from the implement-phase explorer agent.
- The verdict now has a stated boundary: it ranges over documents inside the configured
  internal-documentation location **only**. A discrepancy outside that location is reported
  but never moves the verdict, so two runs over the same tree return the same token. An
  unreadable documentation location is `unestablished`, not `DOCS MISSING`.
- `discharged` now has a stated bar — you can state the duty's answer and cite where you
  read it. A qualification naming something relied on but not read makes the status
  `unestablished`; one that merely bounds a verified method's reach does not.

### Internal

- The write-mode half of the skill moved to `skills/docs-verify/references/write-mode.md`,
  loaded only on the write path behind a **fail-closed** boundary-marker gate — a reference
  that cannot be read, or whose markers do not match its own path, stops the run rather than
  letting it edit documentation without its scope constraints. A report-only peer never
  loads it.

Every flag, verdict token, report field name, and duty name is unchanged, so
`/prflow:create-issue` Step 1, the issue template's Documentation Drift coupling, and the
existing contract pins are unaffected.
