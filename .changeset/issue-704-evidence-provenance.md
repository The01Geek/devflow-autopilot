---
bump: patch
---

### Added

- `/devflow:create-issue` now records **repository-baseline provenance** for load-bearing
  claims and **reproducible evidence** for audit findings, both owned by
  `scripts/issue-audit-state.py` so they survive a context compaction.
  - New subcommands `record-claim-baseline`, `check-claim-staleness`, and
    `query-claim-baselines`. A claim records a captured revision plus a **per-class
    measured-content identity** — a content digest of the measured paths for a
    location-sensitive anchor, a digest of the re-executed **full-domain** search result for a
    count or coupled-site inventory — so the staleness re-check localizes: an unrelated base
    advance leaves a location anchor fresh, while an occurrence added outside the original hit
    set marks a count stale. The comparison reads no repository history, so a shallow clone
    resolves a normal baseline.
  - New subcommands `record-finding-evidence` and `query-finding-evidence`, a **dedicated
    per-finding evidence channel keyed by finding id** with its own bounded encoding —
    deliberately not the one-line `record-adjudication --ledger-stdin` summary transport,
    which refuses newlines and `<field>=` tokens by contract. Evidence text is stored as data
    and JSON-encoded at the print boundary, so instruction-shaped auditor text can forge
    neither a line nor a field, and is never executed.
  - The Step 3.6 auditor's per-finding bar now requires a locator, the exact command, its
    observed output, and the baseline revision it was captured against; adjudication became
    **proportionate in scope** — a low-risk finding with complete, non-conflicting evidence has
    its conclusion re-derived from the locator by a bounded check rather than a fresh
    whole-repository investigation, while high-risk, conflicting, and incomplete findings are
    fully independently verified. Whether the conclusion is checked is unchanged.

All new fields are additive under the unchanged `schema_version`, so an existing on-disk state
file still loads; an absent baseline reads as possibly-stale, never as fresh. Every arm is
best-effort and never blocks issue creation.
