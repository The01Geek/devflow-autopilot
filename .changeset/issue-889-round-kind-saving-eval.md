---
bump: patch
---

### Changed

- `scripts/create-issue-context-eval.py` now attributes the Step 3.6 auditor's own
  `isSidechain` `usage` records to audit rounds, deriving round boundaries from the
  transcript's own `record-dispatch --round N` records and reading the round→kind
  labelling from the audit state file best-effort (every degraded state-file shape
  yields `unestablished` per-kind figures, never a number and never a crash). It
  reports a per-run per-round breakdown, per-kind auditor-cost medians, a
  `--before`/`--after` paired-delta mode (attributed auditor cost, per-run context,
  round count, finding count — never latency), and the three escaped-defect proxies
  (`record-reopen` count; the scope-escape count with its unattributable denominator;
  and a declared post-filing class reported `unestablished`). Wall-clock is reported
  `unestablished` on this tier, and the main-thread context figures are a secondary
  axis.

### Added

- `scripts/issue-audit-state.py` per-finding ledger entries now record an optional
  `quoted_draft_line` draft-space coordinate (ingested via a `<status>@<n>: <summary>`
  ledger line, validated at the read boundary), so the scope-escape proxy compares two
  coordinates in the draft's own space.
