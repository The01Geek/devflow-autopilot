---
schema: 1
kind: growth
---

## Files

- `skills/review-and-fix/SKILL.md` (+34 bytes) — the root `### Schema` block gains the
  `sweep_defs_read` and `sweep_evidence` unconditional fields and the `reference_reads`
  conditional field; the `fix-delta-gate.md` failure-map row's stale "the formal
  `reference_reads.fix_delta` field is the #541 follow-up" parenthetical is rewritten to
  state what now ships. The net is small because the review-round-2 fix that added the
  mandated `reason` key to the `reference_reads` example was paid for by trimming an
  inline `park_calibration` comment whose content `loop-control.md` already owns
  authoritatively — keeping the initial load inside its ceiling without renegotiating it.
- `skills/review-and-fix/references/error-handling.md` (+66 bytes) — the synthesized-record
  enumeration now points at `ITER_SYNTH_EXPECTED_FIELDS` instead of restating a field list
  that the evidence-field addition had made stale.
- `skills/review-and-fix/references/fixing.md` (+2108 bytes) — item 7's "Conditional
  gate/sweep fields" paragraph gains the authoritative `reference_reads` specification
  (conditional contract, registry keying, shape, the `status`/`outcome`/`reason` semantics
  with both `not_verified` arms named, and the APPROVE-family prohibition).
- `skills/review-and-fix/references/fix-delta-gate.md` (+955 bytes) — the Step 3.5 gate
  gains its durable-record producer obligation: persist the gate outcome into
  `reference_reads.fix_delta`, covering the clean / refixed / promoted / both-failure-arm
  paths and preserving the two failure arms' distinct breadcrumbs in `reason`.

## Justification

These bytes are the *specification* of a record field, and a record field's specification
has to sit where the writer and the gate are, not in a conditional reference — a producer
that must be read only when someone goes looking for it is a producer that silently does
not run.

Three properties make the growth load-bearing rather than editorial:

1. **The field had a behavioral outcome but no schema.** Issue #530 shipped the fix-delta
   gate's fail-closed outcome (not-verified prohibits a clean approve) *behaviorally*,
   deliberately deferring the formal field to keep the split PR reviewable. That left a
   real defect surface: the outcome existed with no durable record, so nothing downstream
   could read it and the SKILL.md failure-map row carried a parenthetical promising a
   follow-up. The prose added here is what closes that gap; removing it would return the
   run to an outcome nothing records.

2. **`fixing.md` item 7 calls itself the authoritative record shape.** A conditional field
   specified anywhere else would contradict that claim. The `sweep_defs_read` /
   `sweep_evidence` half is not new prose at all in spirit — those fields were already
   mandated by item 7 and pinned by the #478 assertions; this change reconciles them into
   the schema block and `ITER_EXPECTED_FIELDS` so item 7, the schema block,
   `ITER_EXPECTED_FIELDS`, and the writer's jq object finally agree. The
   growth is the cost of making an existing, already-written contract *checkable*.

3. **The producer obligation must sit at the execution point it gates.** Per the
   operand-trace sweep's stated-policy rule, a policy described only in a thematic section
   leaves the agent reaching the enforcement point with nothing to execute. The
   `fix-delta-gate.md` bytes are the obligation placed at the gate itself, which is
   precisely where an agent-executed policy has to live to fire at all.

No ownership transferred and no prose was superseded, so this is `growth`, not `cutover`:
no executable helper took over a decision the prose previously owned. The new machine-side
enforcement (`ITER_EXPECTED_FIELDS` / `ITER_SYNTH_EXPECTED_FIELDS` membership, the
`--self-check` consumer, and the `lib/test/run.sh` LR_SCHEMA guard and its `#541` pin block)
*complements* the prose rather than replacing
it — the prose states the contract the agent must execute; the tests keep the four mirror
sites from drifting apart. Nothing was removed, so there are no retired pins to account for.
