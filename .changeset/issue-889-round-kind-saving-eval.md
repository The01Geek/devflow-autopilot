---
bump: patch
---

### Changed

- `scripts/create-issue-context-eval.py` now attributes the Step 3.6 auditor's own
  `isSidechain` `usage` records to audit rounds, deriving round boundaries from the
  transcript's own `issue-audit-state.py record-dispatch --round N` records and reading
  the round→kind labelling from the audit state file best-effort (every degraded
  state-file shape yields `unestablished` figures with a stderr breadcrumb naming the
  path, never a number and never a crash). It reports a per-run per-round breakdown
  carrying each round's recorded kind, per-kind auditor-cost medians, and a
  `--before`/`--after` paired-delta mode whose four keys are each a corpus-wide total
  named as one (total attributed auditor cost, total peak context, total round count,
  finding count — never latency, and `unestablished` rather than a measured-looking
  number when either corpus is empty or under-counted). Of the three escaped-defect proxies, the
  `record-reopen` count is measured and the declared post-filing class is reported
  `unestablished` by construction; the scope-escape count and its unattributable
  denominator read `unestablished` on any state file carrying a targeted round, because
  no producer records a `draft_lines` span on a targeted round's scope — the instrument
  reports that gap rather than the `0` that would read as "no defects escaped scope"
  (a state carrying no targeted round at all reports a genuine, established `0`).
  Wall-clock is reported `unestablished` on this tier, and the main-thread context
  figures are a secondary axis.

### Added

- `scripts/issue-audit-state.py` per-finding ledger entries now record an optional
  `quoted_draft_line` draft-space coordinate, ingested via the `<status>@<n>: <summary>`
  ledger line that `skills/create-issue/references/step-3-6-audit.md` now documents and
  validated at the read boundary — the finding-side coordinate the scope-escape proxy
  needs. The scope-side coordinate (a targeted round's draft-line span) is not yet
  recorded, so the proxy stays `unestablished` until it is.
