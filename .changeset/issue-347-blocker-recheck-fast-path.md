---
bump: patch
type: Added
---

- **Review engine: scoped blocker-recheck fast path.** A standalone `/devflow:review` on a
  PR whose most recent recorded verdict is a REJECT driven *solely* by enumerated
  self-contradicting-diff carve-out blockers (zero checklist FAIL/INCONCLUSIVE, no
  verdict-driving agent finding at or above threshold) — and whose commits since the rejected
  head touch only the enumerated blocker sites — now re-verifies each named blocker at HEAD
  with a blinded verifier and posts a refreshed verdict through the existing Phase 4.4
  machinery, instead of a full four-phase re-review. An APPROVE flows into the existing
  `dismiss-stale-rejections.sh` housekeeping unchanged; any unmet precondition, unparseable
  prior report, or intervening change outside the blocker sites falls through fail-closed to
  the full pipeline, and any still-unfixed blocker re-REJECTs. The gate is off for
  `/devflow:review-and-fix` (it passes `head_override = local`), so the fix loop never takes
  the fast path mid-loop and the shared engine stays single-sourced. (#349)
