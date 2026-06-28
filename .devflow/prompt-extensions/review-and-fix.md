# DevFlow repo — calibration policy for `/devflow:review-and-fix`

This repository (the DevFlow plugin itself) is the loop's own subject. Three times the
in-loop review-and-fix pass concluded with an APPROVE-family verdict after **parking** a
substantive finding as a Suggestion / advisory non-blocking note, and a later standalone
`/devflow:review` (or a re-review on the same PR) re-raised that exact point as **Important
or Critical** — forcing human follow-up commits the loop should have made itself. The loop's
machinery (shadow pass, coverage tripwires, post-shadow edit gate) is not the gap; the gap is
the loop's own **severity self-grading at the moment it decides to park-and-ship** rather than
fix. This extension raises that bar. It is **additive** — it adds a calibration check on top
of the existing Step 2.5 demotion and Loop Exit conclude behavior; it overrides nothing, and it
is review-and-fix-only on purpose (standalone `/devflow:review` already catches these, which is
the very asymmetry the recurrence exposes).

## The recurring under-grade — three concrete shapes (treat as Important, do not park)

Before you park ANY finding as advisory / Suggestion (Step 2.5 demotion, or the
Suggestion/Minor-only conclude path in Step 2), and before you let the loop converge on an
APPROVE-family verdict, check each surviving-but-parked finding against these three shapes drawn
from this repo's own re-review history. A finding matching any of them is **Important, not
advisory** — route it to Step 2.5 → Step 3 (fix it, or push it back through the structured
`skip_category` flow with evidence), do **not** park it and conclude:

1. **Fail-open guard / coverage hole in code or spec this PR itself added.** A guard, tripwire,
   coverage-invariant, or contract clause whose comparand can be absent, keyed on the wrong
   signal, or under-specified vs. the issue's acceptance criteria — so it *asserts* an invariant
   but passes on the inputs it was added to catch (the `unverified-assumption` class in
   `CLAUDE.md`). This is what PR 62's standalone re-review flagged Critical (the roster tripwire
   keyed on the wrong signal; the AWUSF re-review contract left fail-open holes) after the in-loop
   shadow reported clean. A new guard in this PR's own diff is **in-scope by definition** — never
   park it as "pre-existing" or "future polish."

2. **A breadcrumb / error message that overclaims relative to the path that emits it.** A
   diagnostic that states a precondition the emitting path does not actually guarantee (e.g. a
   zero-record breadcrumb that says "from non-empty content" on a transport that has no non-empty
   precondition), so a real input fails loud with a *misdirected* message — the misleading-breadcrumb
   bug class `CLAUDE.md` holds best-effort parsers to. PR 104 shipped exactly this parked as a
   non-blocking advisory after **both** Devflow Review passes flagged it (one Important). If both
   the engine pass and the shadow name a breadcrumb/error-accuracy finding, that corroboration
   alone disqualifies it from advisory parking.

3. **A deferral the gate will not actually honor, or named-but-unreconciled prose/code drift.**
   Do not record a finding as a Scope-Acknowledged deferral (and do not let the workpad/reflection
   claim it "stays deferred") unless the deferral would actually be **honored** by
   `/devflow:review`'s Phase 4.0 matcher: in this repo the PR author (`The01Geek`) is **not** in
   `devflow.allowed_bots`, so every deferral filed on such a PR is rejected `untrusted-filer` and
   is **inert** — the finding flows through at full severity. A reflection that presents an inert
   deferral as honored is a false convergence signal. Before parking anything as "deferred,"
   confirm the author is a trusted filer; if not, the finding is **not deferrable here** — fix it
   or push it back, and never let the reflection assert it was honored.

## Conclude-gate: the parked list must survive its own re-read

When the loop is about to exit on any APPROVE-family verdict (`APPROVE`,
`APPROVE WITH ADVISORY NOTES`, `APPROVE WITH CAVEAT`, `APPROVE WITH UNRESOLVED SHADOW FINDINGS`),
re-read every parked advisory / Suggestion finding (from `fix_decisions` rows whose
`skip_category` is `advisory-parked`, plus any Suggestion/Minor not actioned) against the three
shapes above **and** against the shadow pass's own findings. If any parked finding matches a
shape, or the shadow re-raised it at any severity, it is **mis-graded**: re-route it through
Step 2.5 → Step 3 within the remaining iteration budget rather than concluding. Only when no
parked finding matches may the loop conclude. Record the conclude-gate outcome as an explicit
`## Devflow Reflection` bullet naming each re-graded finding (or stating "conclude-gate clean:
no parked finding matched a known under-grade shape") — written as evidence you ran the check,
never as a bare assertion.

## Honest-verdict guardrail

Do not let chat output or the workpad reflection describe the in-loop shadow as having
"converged with" or "matching" a standalone `/devflow:review`. The shadow **narrows** the gap to
a standalone pass; it does not close it (these recurrences are the proof). State coverage exactly
as the `{shadow status}` template prescribes — and when a finding was re-graded by the
conclude-gate above, say so plainly rather than presenting the run as having been clean all along.
