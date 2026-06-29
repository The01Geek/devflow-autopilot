# The `/devflow:review-and-fix` shadow review pass

**Skill:** `skills/review-and-fix/SKILL.md` (Step 2.6 *Shadow review*, plus the Loop Exit
*Coverage → Shadow agreement* section and the chat-output `{shadow status}` rendering)

This doc captures the mechanics of the shadow review pass and the structural constraint that
shapes its design, so the constraint is not re-derived (or re-broken) by a future maintainer who
sees "just run the engine in a fresh subagent" as the obvious simplification. It is not.

## What the shadow pass is, and why it exists

`/devflow:review-and-fix` wraps `/devflow:review`'s four-phase engine in a fix loop. The loop runs
up to a configurable number of iterations — `devflow_review_and_fix.max_iterations` (default 5),
resolved once at loop start — before exiting with its latest verdict; the shadow pass below is not
counted toward that cap. Iterations
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
`coverage` field, recorded on the workpad (`.devflow/tmp/review/<slug>/<run-id>/iter-<N>.json`, run-scoped):

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
  - the four **always-on** agents — `devflow:code-reviewer`,
    `devflow:silent-failure-hunter`, `devflow:comment-analyzer`,
    `devflow:requesting-code-review` — unconditionally; **plus**
  - `devflow:type-design-analyzer` iff `has_new_types` is true, and
    `devflow:pr-test-analyzer` iff the test-relevance predicate matches, per
    `/devflow:review`'s Phase 3.1 gates.
- **`engine_self_modifying` adds and removes nothing here.** That override forces the full
  checklist and the four always-on agents on, but the two structural-applicability gates survive
  it — so the expected roster is still "four always-on + each analyzer whose gate is true." Do not
  force the analyzers into the expected roster on an engine-self-modifying diff; that would
  manufacture a phantom shortfall.
- **`devflow:requesting-code-review` is an always-on shadow-roster member.** The final-pass
  reviewer is a first-party DevFlow skill, so it is always present wherever DevFlow runs — there is
  no companion-plugin-unavailable fall-back to apply. It is an always-on roster member, so a shadow
  pass that dispatched only the other three always-on reviewers (or whose final-pass result was lost)
  is a coverage shortfall like any other. The shadow never declares full coverage on a three-of-four
  roster.
- **A structurally-valid but evidence-empty reviewer response counts as "did not return cleanly."**
  Full coverage requires that every dispatched reviewer returned a result that positively shows it
  ran (an assessment/verdict plus a `defect_signature` on every finding). A reviewer that errored
  internally yet emitted `{findings: []}` with no assessment is not a clean reviewer.
- **Checklist skip is not a coverage shortfall — but a *narrowing* skip is tripped.** If the
  shadow's own Phase 0.5 sets `checklist_skipped = "intentional"` (a `small_diff` + `config_only`
  diff), Phase 1+2 don't run and the shadow's Phase-2 fails are empty *by design*. Coverage is about
  the reviewer roster, not the checklist; record `checklist_skipped` on the block so a reader doesn't
  mistake an empty Phase-2 result for a re-audited checklist axis. The risk a mis-set skip drops the
  checklist axis while the roster join still reads `"full"` is closed by a checklist-axis analogue of
  the roster tripwire below: the shadow's skip is honored **only** when the loop's last-iter
  `checklist_skipped` is *also exactly* `"intentional"`. Every other comparand value trips and forces
  Phase 1+2 to run: the loop *ran* the checklist (`null` — the canonical narrowing), the loop's
  checklist generation *failed* (`"failure"` — it never audited the axis either, so a skip on top
  would leave it unaudited), or the comparand is absent/unparseable/unreadable (fails closed like the
  roster tripwire). Only a skip both profiles independently judged legitimate is honored.
- **Dispatched is not collected — a 1:1 join is required.** `coverage: "full"` requires not only
  that the expected roster was *dispatched* but that each dispatched identifier maps to exactly one
  *collected and successfully-parsed* result. A dispatched-but-lost result (launched, never
  collected, or unparseable) is a shortfall like a never-dispatched one. "It's in
  `reviewers_dispatched`" is not evidence the reviewer ran.
- **A too-narrow self-classification cannot silently shrink the reviewer roster.** Because the
  expected roster is computed from the shadow's *own* Phase 0.5, an under-classification would shrink
  the expected and dispatched rosters in lockstep and still read `"full"`. A tripwire compares the
  shadow's own expected gated analyzers against the gated analyzers the loop's last iter actually
  launched — read from the recorded `phase3_dispatched` roster, **not** from `diff_profile` (the
  persisted profile carries `has_new_types` but not the test-relevance predicate, so a profile-vs-
  profile check would be blind to a narrowed `pr-test-analyzer`; the dispatched roster records the
  post-gate launch of *both* analyzers): a narrowing divergence widens *both* the expected roster and
  the dispatch to the union of both sides' gated analyzers; a *missing* last-iter `phase3_dispatched`
  (it is a best-effort field) has no second operand to union against, so it trips to the **full gated
  roster** (both gated analyzers) instead. Either way the widening is fail-closed, so a dropped
  analyzer surfaces as a shortfall rather than passing as full. (This guards the gated-*analyzer* dimension; the parallel risk that a mis-set skip drops the
  *checklist* axis is closed by the checklist-skip tripwire above — the two together cover both ways
  a too-narrow self-classification could otherwise read `"full"`.)
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
does not return) is `not_verified` recorded. That single retry is **global to the whole shadow pass**
(the initial fan-out and any tripwire-widened late reviewer dispatches share the one budget) and
covers **Phase-3 reviewers only** — Phase 1+2 work a tripped checklist re-run forces is engine phase
dispatch, not a reviewer retry. (A forced checklist re-audit that cannot complete still fails closed:
it surfaces as a Phase-2 INCONCLUSIVE, which drives the shadow's verdict to REJECT per the engine's
verdict mapping, which the loop promotes into another iteration — so a degraded re-audit never reads
clean.) **Structural** failures (the `Agent` tool unavailable,
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
asserting a shadow result the persisted record can't back. The headline and the report's Coverage
section both pin to *that same* one-iter-back block (never an earlier iter's block) and evaluate the
lost-write branch before the `"full"` branch, so a lost promotion-triggering block can't make the
report read "full coverage" while the headline reads "not verified."

`APPROVE WITH UNRESOLVED SHADOW FINDINGS` is terminal *for the loop* — it is at the iteration cap and
will not re-review itself, and its unresolved Important findings surface only in chat and the report's
`## Unresolved Shadow Findings` section. A wrapping orchestrator (e.g. `/devflow:implement`) that
chooses to *fix* those findings must re-establish independent coverage by re-running the loop once
over the fix delta; it must not resolve them with an unreviewed final commit. Otherwise the very edit
that answers the shadow ships with no independent eyes on it — the gap this contract closes.

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

**Evidence.** On PR #58 (issue #57) itself — the PR that made the shadow pass parent-orchestrated and
fail-closed — the in-loop shadow agreed with full coverage, yet a subsequent standalone
`/devflow:review` run surfaced several hardening items the in-loop shadow had not caught (none Critical;
they became the follow-up tracked in issue #61). That is the calibration in a single data point:
"shadow agreed, full coverage" meant the in-loop re-sample found nothing new, **not** that the PR
was exhaustively reviewed.

The practical consequence: a clean shadow result is a real signal that the loop converged honestly,
but the human gate — and, for a formal merge signal, a separate `/devflow:review <PR>` run — remains
the exhaustiveness check. A clean shadow *raises confidence* in that gate's outcome; it is never a
criterion for *waiving* it. Treat the separate independent review as the default, not as something a
clean shadow makes optional.

### The highest-risk clean shadow: a diff that changes the review/coverage/gate logic itself

The generic calibration above has a sharpest edge, and it is the one this loop keeps getting wrong:
**when the diff is `engine_self_modifying` and what it modifies is the review engine's own
coverage-, gate-, or shadow-pass logic, a clean in-loop shadow is the *least* trustworthy clean
shadow there is — never read it as sufficient, and require a separate standalone `/devflow:review`
before merge.** The "shared blind spot" of the two bullets above is not a constant here; it is
maximal precisely on this diff shape, because the reviewers are being asked to audit the very
gate/coverage logic the change is rewriting, using a roster that shares whatever blind spot the new
logic is supposed to close. A fail-open hole in a new tripwire, an under-specified verdict-precedence
rule, a coverage join that reads `"full"` over a roster that silently shrank — these are exactly the
defects a clean shadow is structurally weakest at catching, because catching them requires reasoning
*about* the gate rather than *through* it.

This is not hypothetical and not a one-off:

- **PR #62 (issue #61), the hardening spec for the shadow-coverage invariants themselves.** The
  in-loop shadow reported clean; a subsequent standalone `/devflow:review` returned **REJECT** on a
  Critical fail-open — the roster too-narrow tripwire keyed on the wrong persisted signal (it
  compared `diff_profile`, which never stored the test-relevance predicate, so a narrowed
  `pr-test-analyzer` gate read `coverage: "full"` over a shrunken roster). It took twelve substantive
  human follow-up commits across two review cycles to actually defend `coverage: "full"`. The clean
  shadow was honest about what it asserts (the in-loop re-sample found nothing new) and useless as a
  merge signal for this diff shape.
- **PR #104 (issue #100), the `scan.sh` retrospectives-decode hardening.** A finding *both* review
  passes flagged — the `_decode_existing` zero-record breadcrumb over-claims "from non-empty content"
  on the `download_url` transport, which has no non-empty precondition — was parked as a non-blocking
  advisory and shipped unfixed, with no test pinning the `download_url` empty/whitespace-body shape.
  Parking advisories is legitimate by design (see "Advisory findings" in the skill), but on an
  engine-self-modifying diff a *repeatedly-flagged* breadcrumb-accuracy defect in the engine's own
  best-effort parser is the bug class CLAUDE.md singles out — it warrants fixing or an explicit
  standalone-review pass, not silent advisory carry-through.

So the rule, stated operationally: **a clean in-loop shadow does not clear an `engine_self_modifying`
diff that touches review/coverage/gate logic for merge — schedule the separate standalone
`/devflow:review` and resolve its findings first.** The standalone review is mandatory here, not
"default but waivable on a clean shadow." (This narrows nothing for ordinary product-code diffs,
where the shared-blind-spot risk is lower and the standalone review remains the *recommended*
default rather than a hard pre-merge gate — see the Counterfactual note this calibration was
strengthened under.) The two sub-patterns above both fall under the `lenient-verdict` category (a gate ran and returned an
approve-family verdict while a defect it should have caught shipped — for PR #62 the in-loop shadow's
clean verdict over a Critical the standalone review later flagged; for PR #104 a repeatedly-flagged
advisory parked and shipped unfixed); this calibration addresses the dominant one (the
engine-self-modifying clean shadow that a real gate later caught). It does **not** change the advisory-parking mechanics themselves — a repeatedly-flagged
advisory on an engine diff is surfaced here as a case the mandatory standalone review must catch, not
re-litigated as a new auto-fix rule.

### The mechanical layer beneath this calibration (issue #155)

The calibration above is a *judgment* rule — read a clean shadow skeptically on an
engine-self-modifying diff, and route to a standalone review. PR #154 showed why judgment alone is
not enough: its in-loop shadow agreed with full coverage, and it *still* shipped a **vacuous drift
guard** — a `grep -qF` whole-file scan pinned to a literal that also appeared outside the gate, so the
guard stayed GREEN even with the gate it claimed to protect deleted. Wherever a deterministic check is
possible, the defense is now **mechanical**: it lives in `lib/test/run.sh` and fires whenever the suite
runs (CI on every push, or locally) — not in real time mid-loop — so it catches the regression at
suite/CI time no matter whether the loop that produced the diff was driven by the skill or by hand:

- **Target-uniqueness guard (`assert_pin_unique`).** Every SKILL presence-pin across the suite now
  asserts its literal occurs *exactly once* in the resolved SKILL — a duplicated or absent literal fails
  the suite, closing the whole-file-scan hole that let PR #154's guard pass. Originally scoped to the
  park-calibration region, the enforcement is now **repo-wide** (issue #157): the raw `grep -qF`
  presence-pins throughout `lib/test/run.sh` were converted to `assert_pin_unique`, and the guards that
  genuinely can't route through it (non-unique-by-design count assertions, absence pins, case-insensitive
  or loop-variable targets, `--`-leading literals) each carry a `# raw-guard-ok: <reason>` allowlist
  marker. A repo-wide self-scanning meta-test (`count_unallowlisted_raw_skill_guards`) fails if a
  *single-line, echo-driven* raw `grep`-based SKILL guard — any flag spelling, against a `_SKILL` var, a
  `SKILL_`-suffixed loop var, or a literal `…/SKILL.md` path — exists anywhere in the suite without either
  routing through the helper or carrying a properly-formatted allowlist marker. An in-region control
  (`count_region_nonhelper_stmts`) additionally requires every park-calibration region statement to route
  through the helper. The scan itself cannot go vacuous because the pre-existing #155 marker-presence pins
  (the `PARKCAL_GUARD_REGION` BEGIN/END `pin_count == 1` asserts) fail closed if the region markers are
  deleted — `region_lines()` is merely the shared extractor, not the fail-closed control. All are
  mutation-proven: the suite goes RED on a deliberately non-unique pin, on an unallowlisted raw bypass
  guard anywhere in the suite, and on a deleted region marker. Scope caveat: the audit covers
  SKILL-*targeted* guards (a grep against a `_SKILL`/`SKILL_` var or a `…/SKILL.md` path); an identical
  vacuous-whole-file-presence guard against a non-SKILL target is out of scope.
- **Sentinel-completeness signal.** The park-calibration gate (Step 2.6) records a mandatory
  `## Devflow Reflection` bullet on every run — a re-grade routing or the gate-clean sentinel.
  `lib/test/run.sh` pins that sentinel contract, and the `/devflow:review-and-fix` Loop-Exit machinery
  now treats an APPROVE-family conclusion with **no** sentinel/re-grade bullet as *non-convergence* (the
  gate did not run to completion). Combined with the explicit firing-site handoffs at Decide outcome 1
  and the Step 4.5 early-exit, a manually-driven loop can no longer reach an APPROVE-family verdict while
  silently skipping the gate.

These are a *backstop beneath* the prose calibration, not a replacement for it: the mechanical guards
catch a vacuous guard or a skipped gate deterministically, but the judgment rule above — read a clean
engine-self-modifying shadow skeptically and run the standalone review — still governs the cases no
local check can decide. The target-uniqueness guard is also the deterministic, guarantee-class form of
the prose "pin a *target-unique* phrase" advice in the mutation-check rule.

### Calibration is symmetric: the under-grade gate and the over-grade gate are two halves of one defense

The calibration above is about the loop grading a finding **too low** (a real defect parked as a note that a later standalone review re-raises). That is one direction; the loop can also grade a finding **too high**, and the engine defends both directions with a matched pair of gates in `skills/review-and-fix/SKILL.md` that share one root idea — *never trust an emitted severity without a recorded technical evaluation against the finding's observable fail-direction and impact*:

- **Under-grade — the park-calibration gate**, on the **approve** path (before a Decide outcome-1 / Step 4.5 early-exit conclusion). It re-reads parked findings against the under-grade shapes and **promotes** any it catches back through Step 2.5 → Step 3, so a substantive finding cannot ride out as a note.
- **Over-grade — the over-grade calibration gate**, on the **promote** path (before a Decide outcome-2 promotion fires on an emitted `Critical`/`Important` shadow finding). It **flags** a suspected over-grade against *observable* shapes — a defect that fails closed or that the suite catches RED, and a diagnostic-or-cosmetic-only finding with no behavioral fail-direction — so the loop does not spend a full extra engine pass (a promoted iteration plus a re-shadow) on an unexamined label.

The two gates are deliberately **asymmetric in action but symmetric in intent**. The under-grade gate *promotes*; the over-grade gate **flags and requires a recorded technical evaluation — it never auto-demotes**, because silently demoting a wrongly-suspected over-grade would re-open the lenient-verdict hole the rest of the engine exists to close. The shared mechanism that makes both auditable is **recording the per-finding technical evaluation as evidence**: the over-grade gate's required artifact is a structured `fix_decisions` entry (`decision: "severity-calibrated"`, citing the observable fail-direction/impact and the calibrated grade), and a flagged promote-path finding with no such recorded evaluation is treated as **non-convergence** at Loop Exit — so a run that skipped the calibration discipline is detectable by the absence of the evidence rather than dependent on actor diligence. This mechanizes the `receiving-code-review` **symmetric-severity-calibration principle** (a genuine finding can be over-graded; calibrate severity against observable fail-direction/impact in both directions): the principle *states* the discipline engine-agnostically, the gate *enforces* it.

Empirically (issue #155 / PR #156), a high-verbosity reviewer — `silent-failure-hunter` — repeatedly over-graded fail-closed, diagnostic-only defects `Critical`/`Important` in a single run; the over-grade gate makes the technical evaluation that catches such labels a recorded, detectable engine step rather than a matter of actor diligence.

## The fix-delta verification gate (Step 3.5) — a complementary, per-iteration check (issue #159)

The shadow pass audits the **whole diff** once, at **convergence**. That leaves one gap it cannot close cheaply: a regression introduced by **a fix itself**, in the iteration that produced it. A fix is new code; it can ship a fresh `unverified-assumption` / #62/#98 instance — a guard whose accepted-input set is **wider than its downstream consumer's contract**, so it fails open exactly where it claims to fail closed. Caught only by the end-of-loop shadow, such a regression forces the shadow to *promote* a costly extra iteration (PR #153 took three iterations for one issue because iterations 1–2 each re-introduced a weaker-contract guard in their own fix). **Step 3.5** front-loads that detection: after each iteration's fix commit — **every iteration, unconditionally** — the parent dispatches a **blinded subagent** that re-reviews **only that iteration's cumulative fix delta** (`git diff <iter_fix_base>..HEAD`, the iteration's first-fix parent through HEAD, so an inner re-fix can't split the fix across separately-reviewed commits) plus the consumer code it touches, with the loop's prior findings/fix decisions/fixer reasoning withheld — the same blinding model as the shadow's per-reviewer prompts. Its checks include the #62/#98 operand-contract check (the fix's guard accepted-input set must be a *subset* of its consumer's contract — see the **share-the-contract / parse-don't-validate** principle in `receiving-code-review`) and an adversarial input-shape matrix. A new Critical/Important gate finding first passes the over-grade calibration gate (flag + recorded `severity-calibrated` evaluation, never auto-demote), and a re-affirmed one routes back into the same iteration's fix step (capped at 2 inner attempts, then promoted to a cap-counting iteration; at the cap it rides into the shadow's whole-diff audit and a `## Devflow Reflection` bullet). Like the shadow, the gate and its inner attempts do **not** count toward `max_iterations`, and a gate-subagent failure gets one bounded re-dispatch before the loop records `fix-delta not verified` and proceeds (a deterministic delta-base failure gets a distinct breadcrumb, no retry). The Step 2.6 shadow pass and the post-shadow edit gate are **unchanged** by Step 3.5.

## Non-blocking severity-aware exit in `/devflow:implement` (issue #159)

`/devflow:implement`'s Phase 3.3 used to treat `APPROVE WITH UNRESOLVED SHADOW FINDINGS` (and a non-clean bounded re-review) as a hard **Blocked** stop — aborting the whole lifecycle after the "two consecutive non-clean passes" of the capped run plus its one bounded re-review. That was too aggressive: it discarded a review-ready PR over findings that, after over-grade calibration, are frequently advisory. Phase 3.3 is now **severity-aware**: only a *genuine unresolved Critical* (or an unparseable/ungradeable verdict, fail-closed) takes the Blocked path; a residual of only advisory / Suggestion / `severity-calibrated`-down / deferrable-Important findings **soft-proceeds** — surfaced durably (workpad `### ⚠️ Action required` reflections, and the PR body where a deferrals manifest exists) while the run continues to Phase 4. The PR ships review-ready, not auto-merged; the human merger decides. This preserves the human gate without throwing away completed work over diminishing-returns nits.

## Cost

The shadow pass roughly **doubles** the cost of a converging run — one full engine pass that does
not lead to fixes when it agrees. This is why the `step_2_6` telemetry now carries a full-engine-pass
magnitude (tens of agent calls and a Phase-1+1.5+2+3's worth of tokens) rather than the single call
the old single-subagent design logged; `step_2_6` aggregates the whole parent-run Phases 0–4.3
fan-out. The cost is intentional: it matches the manual `/devflow:review`-after-fix workflow
experienced users already pay (net-zero for them, now mechanical), and it buys a credible audit
rather than a self-check that re-derives the loop's own answer.
