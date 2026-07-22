---
bump: minor
---

Require positive per-dimension coverage evidence in the create-issue Step 3.6
fresh-context audit (issue #708). `render-audit-prompt.py` gains an
`enumerate-dimensions` mode that emits a canonical, keyed, count-stable list of
every required audit dimension (generic-floor `g:<slug>` entries plus consumer
`c:<n>` entries), so the orchestrator holds an authoritative operand to join the
auditor's per-dimension coverage outcomes to and to run the byte-identity floor
against.

`scripts/issue-audit-state.py` gains the coverage half of that contract:
`record-coverage` persists a round's per-dimension outcomes and enforces
**totality** against an orchestrator-supplied `--expected-keys` keyset — refusing
an unenumerated key, synthesizing every missing enumerated key as
`unestablished`, and persisting the supplied keyset so the claim stays auditable.
`query-coverage` reports the recorded outcomes with reason discriminators
distinguishing the ways coverage can fail to hold. The boundary trigger gains a
`coverage=` field and the summary line a `coverage_reason=` field, so a run that
is not coverage-backed says why. `coverage=hold` joins the single existing
boundary offer rather than adding a second pause.

`coverage-backed` means evidence of the required shape was present and survived
the text-only anchor floor and the orchestrator's adjudication — never certified
scrutiny.
