---
bump: patch
type: Changed
---

- **Evidence-aware post-shadow grading of parked findings (`/devflow:review-and-fix`, issue #557).**
  The Park-calibration gate no longer re-litigates a below-verdict-threshold shadow re-raise of
  an already-parked finding on **severity alone** — the arm that burned promoted iterations (each
  a full re-shadow) re-parking findings the shadow merely corroborated. After the shadow block is
  recorded, the gate grades each re-raise↔parked-finding pair on **evidence**: the scoped
  sweep-sibling carve-out is evaluated first (precedence), then each shadow finding pairing under
  Phase 3.2 to the **parking-time record** of a member of the **reconciled parked population** (the
  gate's three parked populations across all iterations, minus any member a later iteration applied
  or promoted-and-fixed) receives exactly one of five relations — *equivalent / strengthened /
  contradicted / materially different / ambiguous*. Parking is **preserved** only on positive
  evidence equivalence from well-formed operands (every paired re-raise equivalent, at or below the
  parked severity under a `major`≡`important`/`minor`≡`suggestion` label normalization, and — for a
  rationale-bearing row at or above `$FIX_THRESHOLD` — an anchored rationale); every other outcome,
  and any missing/malformed/unreadable operand, **fails closed to promotion** at the shadow
  re-raise's severity. A single amendment to Step 2.6's novelty definition makes a paired re-raise
  count as **overlap, not new** (the survived-unfixed reconciliation keeps it from ever claiming a
  fixed member's re-raise as a preserved parking), so an earlier-iteration parked re-raise no longer
  slips into Decide outcome 2. Operands are read from additive workpad records only — a
  `parking_evidence {basis, failing_input, source, finding_ref}` object on the rationale-bearing
  `fix_decisions` rows, a `park_calibration.evidence_comparisons[]` block per pair, and a new
  `tools_unavailable` value in the `step25_classification` enum — never from conversational memory.
  Healthy corroboration stays retrospective-clean via a note-kind preservation sentinel that the
  Loop-Exit backstop and Decide outcome 1 recognize as gate-completion; a fail-closed degradation
  surfaces as friction. The shared `/devflow:review` engine, `scripts/workpad.py`, and
  `lib/fetch-pr-context.sh` are untouched. Documented in `docs/shadow-review.md` and
  `docs/DEVFLOW_SYSTEM_OVERVIEW.md` §9.
