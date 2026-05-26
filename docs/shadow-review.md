# The `/devflow:review-and-fix` shadow review pass

**Skill:** `skills/review-and-fix/SKILL.md` (Step 2.6 *Shadow review*, plus the Loop Exit
*Coverage → Shadow agreement* section and the chat-output `{shadow status}` rendering)

This doc captures the mechanics of the shadow review pass and the structural constraint that
shapes its design, so the constraint is not re-derived (or re-broken) by a future maintainer who
sees "just run the engine in a fresh subagent" as the obvious simplification. It is not.

## What the shadow pass is, and why it exists

`/devflow:review-and-fix` wraps `/devflow:review`'s four-phase engine in a fix loop. Iterations
inside that loop **share state**: the orchestrator's context window carries prior findings, fix
decisions, and pushback history forward across iterations. That shared state is useful for fixing
(it lets later iterations skip what was already considered) but it **biases** the loop toward
accepting its own prior conclusions — the engine increasingly treats things as "already considered"
rather than re-examining them.

The shadow pass at Step 2.6 is the loop's **audit**: before the loop declares convergence on a
non-REJECT verdict, the engine runs **again** with the loop's accumulated state withheld, and the
two results are compared. It only triggers when the tentative final verdict is non-REJECT (APPROVE
family); a REJECT verdict skips Step 2.6 and goes straight to Loop Exit. This mirrors what
experienced users already do manually — run `/devflow:review <PR>` after `/devflow:review-and-fix`
— and folds that independent re-review into the loop so a disagreement feeds one more iteration
instead of being left for the human to discover. It directly targets the empirically-observed
"a manual review finds things the fix loop missed" pattern.

## The structural constraint: a subagent cannot dispatch the engine's fan-out

The natural-looking implementation — dispatch one `general-purpose` subagent and tell it to "run
the whole engine in your fresh context" — **does not work**, and the failure is silent.

`/devflow:review`'s engine *fans out to subagents*: Phase 1, Phase 1.5, and Phase 3 dispatch
reviewer/verifier subagents, and Phase 2 dispatches for its agent-path checklist items. But a
**subagent cannot dispatch its own subagents** — nested `Agent`/`Task` dispatch is unsupported by
the harness. This is **structural, not a permissions gap**: granting the `Agent` tool to the
shadow subagent does not fix it.

So a single shadow subagent told to run the engine reaches Phase 3, finds it cannot launch the
reviewer fan-out, and **silently collapses to a degraded single-agent self-check** that returns a
plausible clean `APPROVE`. The audit never actually runs — and a degraded self-check re-deriving
the loop's own answer is the exact false-convergence the step exists to prevent. This was the root
cause fixed under issue #57.

**The fix: the PARENT orchestrator runs the shadow fan-out itself.** The parent *can* dispatch
subagents, so it re-runs `/devflow:review`'s Phases 0 through 4.3 inline — `Glob` for
`**/devflow/skills/review/SKILL.md`, `Read` it in full, and walk its phases — launching every
Phase-3 reviewer normally. (Reading the engine as an inline procedure, rather than invoking it via
the `Skill` tool, is deliberate: `Skill` would run the engine end-to-end including Phase 4.4's
GitHub post, and the loop is silent on GitHub by design. The shadow stops before Phase 4.4.)
Because it reuses Phase 3.1's launch list and per-agent prompts verbatim, the shadow exercises the
**same reviewer set** a standalone `/devflow:review` would on this diff.

## Where independence comes from: per-reviewer prompt blinding, not subagent-context isolation

The old design's independence story was "the shadow subagent's fresh context window has no access
to the loop's state." Once the parent runs the fan-out, **the parent's own context is no longer
blind** — it carries the iter history. Independence therefore moves into the **reviewer prompts**.
This is the **inverse** of the loop's normal iter-N≥2 fix-delta handoff:

- The shadow does **not** run the fix-delta handoff and does **not** pass `prior_phase3_findings` /
  `prior_checklist` / `fix_files` into any shadow phase.
- The shadow does **not** prepend `/devflow:review`'s Phase 3.1 "Prior-findings context (fix-loop
  callers only)" block to any reviewer prompt, and passes `"none"` for the general-purpose
  final-pass reviewer's "Prior-iteration findings (already considered, look for new)" line. That
  "already considered" handoff is correct for a normal fix iteration but **defeats the shadow's
  purpose** — reintroducing it turns the audit back into a self-check.

Each shadow reviewer therefore sees only the diff and the standard task + `defect_signature`
prompt — a fresh context with the loop's findings withheld. The only residual shared state is the
parent's aggregation step, a far smaller bias risk than losing all of Phase 3's coverage to a
degraded subagent.

## The honest-degradation fail-safe: coverage is a positively-verified assertion

A degraded pass must **never** clear a PR with a clean verdict. The guard is the shadow block's
`coverage` field, recorded on the workpad (`.devflow/tmp/review/<slug>/iter-<N>.json`):

- **`coverage: "full"` is something the parent *proves*, not the default-on-no-error.** Before it
  may set `"full"`, the parent computes the **expected reviewer roster** for this run and confirms
  the dispatched roster (`reviewers_dispatched`) covers it. The expected roster
  (`expected_reviewers`) is recorded on **every** outcome — including not-verified — so the
  Coverage section can explain *why* a shortfall was a shortfall, and so a gated-out analyzer is
  never confused with a dropped reviewer.
- **The expected roster is mechanical**, and computed from the **shadow's own** Phase 0.5
  classification (the shadow re-runs Phases 0–4.3, producing its own `diff_profile` — a post-fix
  diff can legitimately flip `has_new_types` or the test predicate, so validate against *that*,
  not the loop's last-iter profile):
  - the four **always-on** agents — `pr-review-toolkit:code-reviewer`,
    `pr-review-toolkit:silent-failure-hunter`, `pr-review-toolkit:comment-analyzer`,
    `superpowers:requesting-code-review` — unconditionally; **plus**
  - `pr-review-toolkit:type-design-analyzer` iff `has_new_types` is true, and
    `pr-review-toolkit:pr-test-analyzer` iff the test-relevance predicate matches, per
    `/devflow:review`'s Phase 3.1 gates.
- **`engine_self_modifying` adds and removes nothing here.** That override forces the full
  checklist and the four always-on agents on, but the two structural-applicability gates survive
  it — so the expected roster is still "four always-on + each analyzer whose gate is true." Do not
  force the analyzers into the expected roster on an engine-self-modifying diff; that would
  manufacture a phantom shortfall.
- **`superpowers:requesting-code-review` unavailable does NOT downgrade-and-proceed in shadow
  mode.** `/devflow:review`'s Phase 3.1 permits falling back to the other reviewers if that skill
  is unavailable; that graceful degradation is **overridden** in the shadow, where
  `requesting-code-review` is an always-on roster member. Its absence is a coverage shortfall like
  any other. The shadow never declares full coverage on a three-of-four roster.
- **A structurally-valid but evidence-empty reviewer response counts as "did not return cleanly."**
  Full coverage requires that every dispatched reviewer returned a result that positively shows it
  ran (an assessment/verdict plus a `defect_signature` on every finding). A reviewer that errored
  internally yet emitted `{findings: []}` with no assessment is not a clean reviewer.
- **Checklist skip is not a coverage shortfall.** If the shadow's own Phase 0.5 sets
  `checklist_skipped = "intentional"` (a `small_diff` + `config_only` diff), Phase 1+2 don't run
  and the shadow's Phase-2 fails are empty *by design*. Coverage is about the reviewer roster, not
  the checklist; record `checklist_skipped` on the block so a reader doesn't mistake an empty
  Phase-2 result for a re-audited checklist axis.
- **Dispatched is not collected — a 1:1 join is required.** `coverage: "full"` requires not only
  that the expected roster was *dispatched* but that each dispatched identifier maps to exactly one
  *collected and successfully-parsed* result. A dispatched-but-lost result (launched, never
  collected, or unparseable) is a shortfall like a never-dispatched one. "It's in
  `reviewers_dispatched`" is not evidence the reviewer ran.
- **A too-narrow self-classification cannot silently shrink the roster.** Because the expected
  roster is computed from the shadow's *own* Phase 0.5, an under-classification would shrink the
  expected and dispatched rosters in lockstep and still read `"full"`. A tripwire compares the
  shadow's `diff_profile` against the loop's last-iter recorded profile; a narrowing divergence (or
  a missing last-iter profile) widens *both* the expected roster and the dispatch to the union of
  the two profiles' gated analyzers, fail-closed, so a dropped analyzer surfaces as a shortfall
  rather than passing as full.
- **Block presence is verified, not assumed, before "shadow agreed" fires.** The Step 2.6 workpad
  append is best-effort and can be lost. Outcome 1 (the "shadow agreed" path) re-reads the appended
  block from disk and confirms a present `coverage: "full"` block before committing; a lost write
  falls through to not-verified, exactly as the Loop Exit render sites already fail closed on a
  missing block.

When the fan-out cannot complete — the `Agent` tool is unavailable, the engine SKILL.md is
unreadable, the shadow's Phase 0.5 can't classify the diff, a reviewer returned nothing / garbage /
evidence-empty, or the dispatched roster falls short for any reason — the parent does **not** fall
back to a single-agent pass and does **not** report a clean verdict. It records
`coverage: "not_verified"` with a `reason` naming what was missing and takes **outcome 3** of
Step 2.6's Decide step: the loop's tentative verdict stands but is reported as *unverified*, never
as agreement.

One bounded exception applies before outcome 3 is recorded (Step 2.6's *Transient vs. structural*
rule): a **single** dispatched reviewer that returned garbage / empty while the rest of the roster
returned cleanly gets **exactly one** targeted re-dispatch first; only if that retry also fails (or
does not return) is `not_verified` recorded. **Structural** failures (the `Agent` tool unavailable,
the engine SKILL.md unreadable, Phase 0.5 unable to classify) and any **multi-reviewer** failure are
immediate `not_verified` with no retry — they will not recover on a re-run. This is a single bounded
retry, not a fall-back to the lenient "treat as inconclusive and proceed" path.

### Fail-closed on both value and block presence

Coverage is **fail-closed in two dimensions**:

1. **Value:** any `coverage` other than a positively-verified `"full"` — including `"not_verified"`,
   `null`, unset, or unrecognized — is treated as `"not_verified"` everywhere downstream.
2. **Block presence:** the Step 2.6 workpad append is best-effort and can fail. If the final
   verdict is non-REJECT but **no** iteration has a `shadow` block at all, that is treated exactly
   as not-verified — only a *present* block with `coverage: "full"` may render the
   "shadow agreed, full coverage" status.

The chat headline and the report's `## Coverage → Shadow agreement` section both state explicitly
whether the shadow ran with full coverage or was not verified, rendering `shadow agreed, full
coverage` only for a present `"full"` block and `shadow agreement not verified` otherwise (dropping
the absolute "All checks approved." / "with caveats." clause when not verified, so the headline
never overclaims relative to its own parenthetical). The separate
`APPROVE WITH UNRESOLVED SHADOW FINDINGS` verdict — outcome 2 hitting the iteration cap — *normally*
carries `coverage: "full"` (the shadow ran fully and *disagreed*) and uses its own dedicated line; it
is never routed through the `{shadow status}` template. That dedicated line carries its own
render-time coverage assertion: the full-coverage block it reads lives "one iter back" (the
promotion-triggering iter) and was written by the same best-effort append that can be lost, so when
that block is absent or not `"full"` the line falls back to a not-verified rendering rather than
asserting a shadow result the persisted record can't back.

## Calibration: "shadow agreed, full coverage" is not "nothing left to find"

The in-loop shadow pass **narrows** the gap between the fix loop's self-assessment and an
independent review — it does not **close** it. Read the strongest possible shadow result,
`shadow agreed, full coverage`, for exactly what it asserts: *a fresh in-loop sample, run with the
loop's prior findings withheld from each reviewer prompt, surfaced nothing new this pass.* It does
**not** assert that there is nothing left to find.

Two structural reasons the gap persists:

- **It is one sample, not a different reviewer population.** The shadow re-runs the *same* engine
  and the *same* reviewer roster the loop already used; blinding the prompts removes the
  *already-considered* bias but not the reviewers' shared blind spots. A genuinely independent
  standalone `/devflow:review` — a separate session, separate accumulated context — samples the
  space differently and routinely finds things a single in-loop re-sample does not.
- **The shadow runs against the loop's own accumulated context.** The parent orchestrator that runs
  the fan-out still carries the iter history; only the per-reviewer prompts are blind. That residual
  shared state is a far smaller bias than a degraded single-agent self-check, but it is not zero.

**Evidence.** On PR #58 itself — the PR that made the shadow pass parent-orchestrated and
fail-closed — the in-loop shadow agreed with full coverage, yet a subsequent standalone
`/devflow:review` run surfaced ~7 hardening items the in-loop shadow had not caught (none Critical;
they became the follow-up tracked in issue #61). That is the calibration in a single data point:
"shadow agreed, full coverage" meant the in-loop re-sample found nothing new, **not** that the PR
was exhaustively reviewed.

The practical consequence: a clean shadow result is a real signal that the loop converged honestly,
but the human gate — and, for a formal merge signal, a separate `/devflow:review <PR>` run — remains
the exhaustiveness check. A clean shadow *raises confidence* in that gate's outcome; it is never a
criterion for *waiving* it. Treat the separate independent review as the default, not as something a
clean shadow makes optional.

## Cost

The shadow pass roughly **doubles** the cost of a converging run — one full engine pass that does
not lead to fixes when it agrees. This is why the `step_2_6` telemetry now carries a full-engine-pass
magnitude (tens of agent calls and a Phase-1+1.5+2+3's worth of tokens) rather than the single call
the old single-subagent design logged; `step_2_6` aggregates the whole parent-run Phases 0–4.3
fan-out. The cost is intentional: it matches the manual `/devflow:review`-after-fix workflow
experienced users already pay (net-zero for them, now mechanical), and it buys a credible audit
rather than a self-check that re-derives the loop's own answer.
