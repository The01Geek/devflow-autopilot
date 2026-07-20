---
schema: 1
kind: growth
---

## Files

- `skills/create-issue/SKILL.md`

## Justification

- Issue #603 makes post-revision finding resolution a recorded lifecycle fact, and the new
  mandatory bytes are the orchestrator-executed half of that mechanism: the quoted-delimiter
  `--ledger-stdin` transport, the reconciliation classification keyed on the
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
- **Review-driven additions (PR #612 review).** Three further increments, each the smallest
  form that discharges its finding. Two are *accuracy* repairs to enumerations the prose
  already carried: the ledger-summary refusal list and the `record-invalidate --reason` rule
  each named only the empty/protocol-token refusals while the tool also refuses a
  record-splitting `\n`/`\r`, so a drafter hitting `reason-control-char` would have met a
  refusal the skill said nothing about. These add no new obligation — they complete a list
  whose incompleteness was the defect, and they cost a clause each rather than a paragraph.
- The third is the one genuinely new obligation: the AC5 residual (a `REVISE` round adjudicated
  with an `unestablished` count records no ledger and goes invisible to both triggers once a
  later ledgered round is latest) has **no** executable owner and is not reachable by one —
  `query-convergence` is truthful about every ledger it can see, and the round in question is
  not one of them, so no tool answer can name it. The prose is therefore the only possible
  owner, and it is stated as a conditional on an **observable** predicate (alongside a
  `basis=resolution` answer) rather than as a standing caution the orchestrator would have to
  remember unprompted.
- **Second review round (PR #612, review iteration 1) — +1842 bytes, three increments.** Each
  is again a conditional keyed to an observable predicate, which is the form this file has
  used throughout; none adds a new standing caution.
  - *The AC5 observable was itself defective and is restated over two operands.* The predicate
    recorded in the bullet above — "a gap in the round numbers `query-findings` returns" —
    only fires on an **interior** gap, and the residual's base case has none: round 1
    adjudicated `REVISE … unestablished` with round 2 ledgered returns only `round=2` lines,
    so the missing number is *leading* and invisible in the returned set. The predicate now
    compares those distinct round numbers against `query-summary`'s `rounds_run=`, making
    **any** completed round contributing no ledger line the trigger. This is a correction to a
    prior increment, not new scope — the growth buys a predicate that fires on the shape the
    residual most commonly takes rather than only on the rarer interior one.
  - *The `query-findings` read-back gained a readability arm at both consuming sites.* The
    prose made that read-back the sole input to the reconciliation classification and to every
    ledger-maintenance decision, and stated the read-back-is-truth policy hard — but supplied
    no instruction to notice that the read *failed*. `findings=none reason=state-unestablished`
    and `reason=foreign-nonce` both render as an empty ledger, so every recurrence would
    classify as fresh, no entry would ever be reopened, and the run would converge
    `basis=resolution` on a defect that was never fixed. The arm mirrors the discrimination
    sub-step 4 already makes for `query-draft-binding`, so it introduces no new idiom.
  - *The ledger-summary refusal enumeration gained the `ledger-unresolved-count` rule* — the
    `unresolved:`-prefixed line count must equal `--unresolved-must-revise`, a count
    independent of `--must-revise`. Same accuracy-repair class as the two enumeration fixes
    above: it completes a list whose incompleteness was the defect, at the cost of one clause.
