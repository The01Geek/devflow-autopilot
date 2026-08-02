---
bump: patch
type: Changed
---

- **`/prflow:create-issue` Step 3.6 scoped audit rounds now re-check resolved claims and
  record the draft-line span that makes the safety trade measurable.** A scoped round
  enumerates every earlier-round ledger entry regardless of resolved status, so the
  drafter's own resolutions become the input the round audits rather than a filter that
  skips them — a run that fixed and confirmed everything no longer dispatches every
  later round cold. Only the claim id and one-line summary travel to the auditor, so a
  re-checked resolved claim never arrives pre-answered, and a run with no earlier-round
  findings still selects the cold whole-draft kind. `record-dispatch` additionally records
  a convex-hull `draft_lines` span on a targeted round's frozen scope, filling the #889
  scope-escape proxy's comparand so the widening's cost is observed rather than argued. (#1105)
