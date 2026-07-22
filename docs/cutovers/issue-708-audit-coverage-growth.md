---
schema: 1
kind: growth
---

## Files

Mandatory prompt rows that grew in this change:

- `skills/create-issue/references/audit-prompt-template.md` — +1,461 bytes (11,351 → 12,812)
- `skills/create-issue/references/step-3-6-audit.md` — **−3,999 bytes** (67,283 → 63,284)

The step-3-6 row is a net *shrink*: the coverage procedure's own bytes landed there, but the
review pass shed more superseded prose than it added (the state owner and its tests are the sole
tested owner of everything cut). The word-budget rows below are the operative figures — bytes are
recorded here only because this artifact's schema is byte-keyed.

No ceiling was renegotiated. The create-issue word budgets are ratchet-down-only, and both
hold at their existing values (`docs/create-issue-budget.md`):

- root 2,732 (ceiling 2,754, unchanged)
- default path 31,202 → **31,262** — exactly at the unchanged 31,262 ceiling, zero headroom
- root + all 9 references 27,198 → 27,258 (`CI614_TOTAL_RECORDED` re-recorded, inside the ±2% band)

`audit-prompt-template.md` is renderer-owned and is **not** on the default-path operand, which is
why the larger of the two growths costs the budget nothing.

## Justification

Issue #708 makes Step 3.6 audit coverage a positive, falsifiable, per-dimension assertion. Two
surfaces have to carry bytes, and neither can be deferred behind a load trigger:

1. **`audit-prompt-template.md`** — the auditor's return contract. A per-dimension coverage
   return that the auditor is never asked for cannot be recorded, so the requirement has to be
   in the rendered prompt itself. These bytes are off the default-path budget by construction
   (the renderer reads the template; the orchestrator's default read set does not).

2. **`step-3-6-audit.md`** — the orchestrator's own procedure. The two data-dependent checks
   (the anchor is not byte-identical to the dimension's rendered prompt text; a quoted draft
   line provably appears in the draft) can only run where the draft and the authoritative
   dimension enumeration are both held, which is the orchestrator, before any reference could
   be loaded conditionally.

What landed there is the *compressed* residue of a ~2,600-byte first draft. Everything the
state owner already enforces was cut rather than restated — the closed outcome set, the
text-only anchor floor, the floor-failure downgrade to `unestablished`, the summary-line fields,
and the offer cap all live in `scripts/issue-audit-state.py` and its tests, per the repo's
helper-cutover convention. The full narration lives in `docs/DEVFLOW_SYSTEM_OVERVIEW.md` §11.
What remains on the mandatory path is only what the orchestrator must *decide*: when to
enumerate, what to check against the re-read draft, what to adjudicate, what to record, and
that `coverage=hold` joins the single existing boundary offer rather than adding a second pause.

## Stated residual — what `coverage-backed` does and does not claim

`--expected-keys` and `--render` are **orchestrator-supplied**: the state owner holds no
template, so it enforces totality against the keyset it is *given*, not against the
renderer's output. An orchestrator that passed only the keys the auditor returned would make
totality vacuous. What the tool does close: it refuses an unenumerated key, synthesizes every
missing enumerated key as `unestablished`, and persists the supplied keyset
(`coverage_expected`) so the claim is auditable after the fact. So `coverage-backed` means
*evidence of the required shape was present and survived the floor and the orchestrator's
adjudication* — never certified scrutiny. That bound is the issue's own stated honesty scope.

## Residual

The default path now sits **exactly** at its ceiling. A further addition to any default-path
member must shed prose first; there is no remaining headroom, and the ceiling is not raisable.
