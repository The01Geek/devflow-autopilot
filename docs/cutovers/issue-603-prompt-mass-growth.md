---
schema: 1
kind: growth
---

## Files

- `skills/create-issue/SKILL.md`

## Justification

- Issue #603 makes post-revision finding resolution a recorded lifecycle fact, and the new
  mandatory bytes are the orchestrator-executed half of that mechanism: the quoted-delimiter
  `--ledger-stdin` transport, the four-arm reconciliation classification keyed on the
  `query-findings` read-back, the shared ledger-maintenance procedure both revision-producing
  sites call, the resolution-basis boundary-offer wording, and the no-amend-path disclosure.
- None of it is relocatable to a reference: every rule fires at an execution point the
  orchestrator reaches mid-procedure, and the "Prose cutover" rule authorizes removing
  decision-owning mandatory prose only once an executable helper is the sole tested owner of
  that decision on every path. Here the helper (`scripts/issue-audit-state.py`) owns the
  *state* transitions and refuses every illegal one, but the *classification* of a new finding
  against prior ledgers is orchestrator judgment the tool cannot make, so the prose is the
  owner and stays mandatory.
- The reconciliation discipline is stated once as a named shared procedure and referenced from
  both revision-producing sites rather than duplicated, which is the smallest mandatory
  footprint that still places each obligation at the execution point it gates.
