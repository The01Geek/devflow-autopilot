---
bump: patch
type: Changed
---

- **`/devflow:create-issue`'s Step 3.6 fresh-context audit now audits the canonical draft file, offers user-chosen audit rounds past the automatic cap, and Step 3.5 self-checks the audit dimensions.** On the normal file arm the orchestrator writes the rendered draft to `issue-draft-<slug>.md` before each round and the auditor reads that file as the sole draft source (with a carriage/identity check), closing the condensation-drift channel a hand-embedded copy opened; a read-only-sandbox embed arm carries the full body verbatim with its own sentinel carriage check. The verdict line gains a third value, `VERDICT: DRAFT-UNREADABLE`. Past the unchanged automatic budget (one audit + at most one automatic re-audit), the skill now offers user-chosen rounds (capped at 3) via the question tool whenever the run is demonstrably unconverged, tracked in a sibling `issue-audit-state-<slug>.md` event log. Step 3.5 gains an inline dimension self-check so the drafter self-catches checklist-class defects before dispatch. (#524)
