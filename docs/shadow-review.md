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
counted toward that cap. Which findings the loop routes to the fixer is itself configurable via
`devflow_review_and_fix.fix_severity_threshold` (default `important`): every finding at or above the
threshold (`critical` > `important` > `suggestion`) is fixed and the rest are parked as advisory,
except that every finding that drove the engine's REJECT (under
`devflow_review.verdict_severity_threshold`) is always in the fix set — so no configuration produces
a REJECT the fixer is configured to ignore. Iterations
inside that loop **share state**: the orchestrator's context window carries prior findings, fix
decisions, and pushback history forward across iterations. That shared state is useful for fixing
(it lets later iterations skip what was already considered) but it **biases** the loop toward
accepting its own prior conclusions — the engine increasingly treats things as "already considered"
rather than re-examining them.

The shadow pass at Step 2.6 is the loop's **audit**: before the loop declares convergence on a
non-REJECT verdict, the engine runs **again** with the loop's accumulated state withheld, and the
two results are compared. This **convergence-time** trigger fires only when the tentative final
verdict is non-REJECT (APPROVE family); a REJECT verdict skips it and goes straight to Loop Exit.
On an `engine_self_modifying` PR the shadow *also* fires on an **early** trigger — once after
iteration 1, regardless of that iteration's verdict (including REJECT) — feeding any new blinded
findings into iteration 2; non-`engine_self_modifying` PRs keep the convergence-time trigger only.
The early pass reuses the same blinded fan-out and is itself uncounted toward the iteration cap (a
promoted iteration 2 it spawns counts, like any promotion). This mirrors what
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

## The dirty-tree backstop: review agents never mutate the working tree

The fan-out the parent runs (and the shadow re-runs verbatim) dispatches advisory reviewers over a
diff. Those agents must be **read-only with respect to the working tree** — a reviewer that edits a
tracked file, runs a live half-revert and forgets to restore it, or stages a change leaves the
orchestrator's tree silently corrupted, which can flip the orchestrator's *own* `assert_pin_unique`
checks to a phantom RED (the failure observed in the `/devflow:implement 186` run). Two coupled
layers close that hole.

**The contract.** Every first-party review/analysis agent definition — `code-reviewer`,
`silent-failure-hunter`, `comment-analyzer`, `type-design-analyzer`, `pr-test-analyzer`, and the
vendored `requesting-code-review` final pass — states the agent must never modify working-tree
source files, the index, HEAD, or branch state, and that any mutation/half-revert verification is
done **on a temporary copy made with `mktemp`, never in place**.

**The deterministic backstop (`skills/review/SKILL.md` Phase 3.1/3.2).** Independently of agent
compliance, the shared engine snapshots the tree with `git status --porcelain -z` immediately
**before** the Phase 3.1 batch (into a temp file — `-z` output carries NUL bytes a bash `$(...)`
variable cannot hold) and compares **after** it returns. On divergence it records an Important
finding with an attributable breadcrumb (never silently discarded) and **restores only the snapshot
delta** — paths clean at snapshot time that became dirty during the dispatch window — computed *by
path column* (status prefix stripped from each `-z` record), so a path the orchestrator had already
modified is left to the human rather than clobbered. The restore is `git checkout HEAD -- <path>`
(from **HEAD**, so a *staged* agent mutation is undone rather than re-materialized from the index),
followed by a tree-state re-check that trusts the re-checked status, not the exit code: a path still
dirty afterward (an untracked or staged-new file) is surfaced per-path, never falsely reported as
restored.

**Why `-z` matters.** Plain `git status --porcelain` **C-quotes** a path containing a space or
special character (`"my file.txt"`); that quoted token is not a real pathspec, so `git checkout`
matches nothing and the restore is a **silent no-op** while reporting success. `git status
--porcelain -z` emits the path **unquoted and NUL-delimited**, so a spaced/special filename is
restored correctly. A rename/copy under `-z` is a two-record shape (`R  <new>\0<old>\0`); the
snapshot read loops consume the bare orig-path continuation rather than mis-parsing it
(the final restore loop only ever sees the rename-free delta set).

**Fail-closed and read-only-profile no-op.** Both snapshots are rc-checked: a failed before-snapshot
**disables** the backstop for that dispatch (it never restores off an empty baseline, which would
authorize `git checkout` against the orchestrator's own live edits), and a failed after-snapshot is
surfaced as a *distinct* breadcrumb rather than misattributed as an agent mutation. In the read-only
`/devflow:review` profile the agents have **no write tools**, so the snapshots match and the restore
never fires; the backstop earns its keep in the write-enabled `/devflow:review-and-fix` and
`/devflow:implement` tiers — including the shadow pass, which re-runs these phases verbatim.

**Residuals it does NOT auto-restore.** (1) A **true rename/copy** (status `R`/`C`) — undoing a
staged rename safely needs index surgery, so it is *surfaced* (named in a breadcrumb) and left for
the human + the shadow. (2) An agent's further edit to an **already-dirty path that does not change
its status byte** — it produces an identical `-z` record, so the divergence test cannot detect it.
Both residuals fall to the shadow pass + the post-shadow edit gate.

## Where independence comes from: per-reviewer prompt blinding, not subagent-context isolation

The old design's independence story was "the shadow subagent's fresh context window has no access
to the loop's state." Once the parent runs the fan-out, **the parent's own context is no longer
blind** — it carries the iter history. Independence therefore moves into the **reviewer prompts**.
Prior-findings leakage is one channel. Topic-priming is a second, distinct channel: even without pasted
findings, an orchestrator-added request to focus or prioritize a surface steers what the reviewer looks
for. This is the **inverse** of the loop's normal iter-N≥2 fix-delta handoff:

- The shadow does **not** run the fix-delta handoff and does **not** pass `prior_phase3_findings` /
  `prior_checklist` / `fix_files` into any shadow phase.
- The shadow does **not** prepend `/devflow:review`'s Phase 3.1 "Prior-findings context (fix-loop
  callers only)" block to any reviewer prompt, and passes `"none"` for the general-purpose
  final-pass reviewer's "Prior-iteration findings (already considered, look for new)" line. That
  "already considered" handoff is correct for a normal fix iteration but **defeats the shadow's
  purpose** — reintroducing it turns the audit back into a self-check.

Every shadow-pass subagent prompt the parent composes uses the engine's verbatim per-agent prompt,
plus consumer prompt-extension text whose provenance is classified before any shadow dispatch, plus only the
shadow engine's own run-scoped full-diff artifacts and permitted repository paths. Provenance-clean
extension text is permitted composition; extension text that fails either check remains loaded but
is recorded as an addendum, so it cannot produce an attested clean result. This covers Phase 1 checklist-generators, the
Phase 1.5 deduper, Phase 2 agent-mode verifiers, Phase 3 reviewers including the final-pass reviewer,
and tripwire-widened late dispatches under either shadow trigger. The parent adds no focus,
prioritization, or scoping clause. The Step 3.5 fix-delta gate and Loop Exit post-shadow delta-review
are explicitly delta-scoped by design, so their delta scope is not an addendum.

Extension provenance is checked without a base-ref read: `git status --porcelain -- <path>` must
exit successfully with empty output, and the readable run-cached changed-file list must omit the
extension path. The extension is still loaded when either check fails or either operand cannot be
established, but the local-status, reviewed-diff, or provenance-not-established failure is named in
`prompt_addenda`. An error or unreadable input never defaults to provenance-clean.
Likewise, the only permitted diff files are Phase 0.2's `diff.patch` and Phase 1's batch slices as the
shadow engine produced them for the full diff. A regenerated, filtered, or subsetted artifact set is
topic steering moved to another channel and is recorded as an addendum.

**Blinding boundary (stated as a contract).** In addition to the prompt classes and permitted
composition above, no shadow prompt carries a workpad path or workpad content. The workpad holds
exactly the loop state this blinding
withholds (iteration history, fix decisions, prior findings), so passing a workpad path — or pasted
workpad content — into a shadow prompt would re-open that channel and turn the audit back into a
self-check. This matters more now that the engine hands diffs to Phase 1 and Phase 3 agents **by
file reference** (the generator receives a `Diff path:` to its batch slice, not inline content, so
the diff never transits the orchestrator's context): the reference-based handoff must not become a
leak channel for the loop state the blinding withholds — the artifacts it hands shadow prompts are
diff files and repo paths only.

**Why the shadow still re-Reads the engine fresh (read-reuse was considered and rejected).** Step
2.6 keeps its mandatory fresh re-Read of `skills/review/SKILL.md` on every shadow pass; skipping it
when the diff does not touch the engine file was considered and **rejected**. The reuse premise —
that Step 1's Read is still verbatim in the parent's context at Step 2.6 — is unverifiable from
skill prose: context compaction on a long run can replace the verbatim copy with a lossy summary,
and the cloud tier's auto-resume machinery restarts runs in a *fresh* context where the Step-1 read
never happened. Executing the engine from a possibly-degraded memory violates the "Read on every
Step 1; never improvise" rule that exists because paraphrase drift caused real historical
divergence, and the failure mode — a silently improvised audit — is invisible. The tokens it would
save are the smallest lever available and do not justify an unverifiable precondition, so the
fresh re-Read stays.

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

### Fail-closed on coverage, block presence, and prompt composition

Coverage remains a pure reviewer-roster measurement. Prompt composition is fail-closed as a separate operand:

1. **Value:** any `coverage` other than a positively-verified `"full"` — including `"not_verified"`,
   `null`, unset, or unrecognized — is treated as `"not_verified"` everywhere downstream.
2. **Block presence:** the Step 2.6 workpad append is best-effort and can fail. If the final
   verdict is non-REJECT but **no** iteration has a `shadow` block at all, that is treated exactly
   as not-verified.
3. **Prompt composition:** clean convergence and the clean-agreement renders require a present block
   carrying both `coverage: "full"` and `prompt_addenda: "none"`. An addenda array names the recorded
   additions in the not-verified rendering; an absent field renders `attestation not recorded`, never
   an accusation of steering. Outcome 1 re-reads both persisted operands, repairing an absent
   attestation once only while the composing context can still record the truthful value.

The attestation never gates outcome 2 and never changes `coverage`. A full-roster pass that surfaces
new Critical/Important findings promotes them unchanged even with addenda, preserving the attestation
on the block. A full-roster pass with nothing to promote but no `"none"` attestation keeps
`coverage: "full"`, records `verdict: null` and a reason, and follows the outcome-3 downstream
treatment: the tentative verdict stands but is not independently verified.

The chat headline and the report's `## Coverage → Shadow agreement` section both state explicitly
whether the shadow ran with full coverage and attested prompt composition or was not verified,
rendering `shadow agreed, full coverage` only for a present block with both required operands and
`shadow agreement not verified` otherwise (dropping
the absolute "All checks approved." / "with caveats." clause when not verified, so the headline
never overclaims relative to its own parenthetical). The separate
`APPROVE WITH UNRESOLVED SHADOW FINDINGS` verdict — outcome 2 hitting the iteration cap — *normally*
carries `coverage: "full"` (the shadow ran fully and *disagreed*) and uses its own dedicated line; it
is never routed through the `{shadow status}` template. That dedicated line carries its own
render-time coverage assertion: the full-coverage block it reads lives "one iter back" (the
promotion-triggering iter) and was written by the same best-effort append that can be lost, so when
that block is absent or not `"full"` the line falls back to a not-verified rendering rather than
asserting a shadow result the persisted record can't back. An addenda array or absent attestation on
that promotion block adds a caveat to the dedicated line and Coverage entry without changing the
verdict. The headline and the report's Coverage
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

The prose mutation-check rule itself carries two further requirements beyond "break it and watch it go
RED," shared verbatim between the implement test-first gate (`skills/implement/phases/phase-2-implement.md`) and the fix
loop (`skills/review-and-fix/SKILL.md` Step 3). First, **bake the half-revert into the suite**: a
mutation-check run once by hand proves the pin caught the regression only at authoring time, so the pin
must instead be expressed through the framework's *removal-proof assertion* — the assertion form that
itself proves *PASS with the pinned text → FAIL without it* — so the check re-runs on every suite
execution (`assert_pin_red_on_removal` is this repo's whole-line removal-proof form — it drives an
`assert_pin_unique` probe over the text-removed file and asserts the PASS→FAIL transition). For a
**behavioral-fix** pin, #375 mandates the stronger mutation-taking sibling `assert_pin_red_under`
(`name literal mutation [file]`): it applies a specific `sed -E` regression — one that deletes *only*
the operative sentence — to a scratch copy and asserts the pin flips PASS→FAIL under *that* mutation,
so a framing-only pin the operative mutation leaves present-and-unique is reported RED for vacuity —
a discrimination whole-line removal cannot make. Second, **confirm the guard
registered**: a green suite is not evidence a guard *ran*, so after adding any guard, confirm its named
assertion appears in the run as a PASS *and* that the suite's assertion count rose by what was added — a
guard that silently no-ops (an assertion helper invoked before it is defined, a test file the runner
never sources, a setup probe that returns success on failure) asserts nothing while the suite stays
green.

### Calibration is symmetric: the under-grade gate and the over-grade gate are two halves of one defense

The calibration above is about the loop grading a finding **too low** (a real defect parked as a note that a later standalone review re-raises). That is one direction; the loop can also grade a finding **too high**, and the engine defends both directions with a matched pair of gates in `skills/review-and-fix/SKILL.md` that share one root idea — *never trust an emitted severity without a recorded technical evaluation against the finding's observable fail-direction and impact*:

- **Under-grade — the park-calibration gate**, on the **approve** path (before a Decide outcome-1 / Step 4.5 early-exit conclusion). It re-reads parked findings against the under-grade shapes and **promotes** any it catches back through Step 2.5 → Step 3, so a substantive finding cannot ride out as a note.
- **Over-grade — the over-grade calibration gate**, on the **promote** path (before a Decide outcome-2 promotion fires on an emitted `Critical`/`Important` shadow finding). It **flags** a suspected over-grade against the *observable* over-grade shapes — whose **single definition** lives in the shared engine (`/devflow:review` SKILL.md Phase 4.1.5, *Over-grade advisory annotation*), consumed by both skills rather than forked: a defect that fails closed or that the suite catches RED, a diagnostic-or-cosmetic-only finding with no behavioral fail-direction, and an uncorroborated single-source `Critical`/`Important` from an empirical over-grader (`silent-failure-hunter` / `pr-test-analyzer`) — and, crucially, a defect that fails **open** never matches the first shape no matter that its limitation is documented or its trigger input contrived, because "documented" and "contrived" are disclosure facts, not severity facts — so the loop does not spend a full extra engine pass (a promoted iteration plus a re-shadow) on an unexamined label.

**Standalone `/devflow:review` annotates, but never demotes (issue #195).** The over-grade shapes are defined once in the shared engine (Phase 4.1.5), so standalone `/devflow:review` — which runs the same Phases 0–4.3 but has **no fixer** to record a `severity-calibrated` evaluation — applies the same shapes as an **advisory annotation only**: it appends a "suspected over-grade: shape *n* — observable fail-direction is *X*" note to the matching finding's line in its report and **leaves the verdict computation untouched** — with one deterministic exception (the in-code-comment cap, below). For the advisory-annotation shapes the annotation never demotes a finding, never alters its severity, and never clears or downgrades a REJECT — a flagged `Critical` still drives REJECT. Its sole guarantee is to let a human reading a bare standalone-review REJECT distinguish a genuine blocker from a diminishing-returns over-grade without re-deriving the calibration. The full **flag-and-record** gate (recorded evaluation required, non-convergence enforcement) remains fix-loop-only, because only the loop has a fixer to record the evaluation.

**One deterministic exception — the in-code-comment cap.** Shape 2's *in-code-comment* sub-case is a *classification* rule, not an advisory annotation: a finding whose sole observable impact is an inaccurate/stale in-code comment on a comment the diff did **not** add or modify is deterministically capped at Suggestion/Minor and does **not** drive a Phase 4.2 REJECT, regardless of the grade a review agent assigned. This does not reopen the #195 lenient-verdict hole, because the cap is keyed only on two observable properties (the impact is solely an in-code comment; the comment was not diff-touched), never on a re-judgment of merits — and it is narrow: it **excludes** any comment the diff added or modified (still a non-demotable self-contradicting-diff REJECT) and covers **in-code comments only** (log / breadcrumb / error-message surfaces keep advisory-annotate-only treatment). Standalone `/devflow:review` applies the cap as a classification; `/devflow:review-and-fix`'s Step 2.6 honors it by recording the required `severity-calibrated` evaluation deterministically (evidence = the deterministic comment-only cap), so a capped finding cannot drive a Decide-outcome-2 promotion. It is single-sourced in Phase 4.1.5 and consumed by both skills.

**The truthfulness partner — the pre-verdict truthfulness sweep (Phase 4.1.6).** The in-code-comment cap governs a pre-existing, diff-untouched inaccurate comment (≤ Suggestion, no REJECT); its mirror on the *diff-touched* side is the **truthfulness sweep**. Shape 2 explicitly **excludes** a false-against-HEAD diff-added/modified doc line, comment, example, or command-form from the cosmetic-wording class — that is a truthfulness defect (a `documented_falsehood`), not a demotable Suggestion — and the sweep enforces it: after the over-grade scan and before the verdict, it runs over **every** Phase-3 finding **regardless of severity chip** (it does *not* inherit the over-grade scan's Critical/Important/Major scope, because a mis-filed falsehood lands at Suggestion). It is **promote-only** — for a finding whose subject is a diff-added/modified artifact, a claim **demonstrated** false against HEAD is routed into the Phase 4.2 self-contradicting-diff carve-out (REJECT) independent of the producing agent's framing and chip, while an inconclusive check leaves the finding exactly as filed; it never demotes, downgrades, or clears anything, and a clean pass emits a visible `truthfulness sweep: no finding promoted` line. The sweep also carries a **diff-scan input** — an *intra-diff contradiction scan* that, independent of any finding, cross-products the diff's added absolute claims (a universal — "every", "never", "is caught by the same rule") against its added-or-retained limitation notes about the **same symbol** and files a contradicting pair as a non-demotable `documented_falsehood`; this closes the PR #340 case where a diff published an absolute claim while retaining a contradicting limitation and no agent flagged it, so a per-finding sweep had nothing to iterate over. Like the cap, it is single-sourced in Phase 4.1.5/4.1.6 and inherited by both `/devflow:review` and `/devflow:review-and-fix` through the shared engine. This is the same promote-only asymmetry as the under-grade gate: the engine promotes on demonstrated evidence, never auto-demotes on suspicion.

The two gates are deliberately **asymmetric in action but symmetric in intent**. The under-grade gate *promotes*; the over-grade gate **flags and requires a recorded technical evaluation — it never auto-demotes** (the deterministic in-code-comment cap above is not a counterexample: it supplies the required recorded evaluation deterministically from an observable property, rather than auto-demoting an unexamined *suspected* grade), because silently demoting a wrongly-suspected over-grade would re-open the lenient-verdict hole the rest of the engine exists to close. The shared mechanism that makes both auditable is **recording the per-finding technical evaluation as evidence**: the over-grade gate's required artifact is a structured `fix_decisions` entry (`decision: "severity-calibrated"`, citing the observable fail-direction/impact and the calibrated grade), and a flagged promote-path finding with no such recorded evaluation is treated as **non-convergence** at Loop Exit — so a run that skipped the calibration discipline is detectable by the absence of the evidence rather than dependent on actor diligence. This mechanizes the `receiving-code-review` **symmetric-severity-calibration principle** (a genuine finding can be over-graded; calibrate severity against observable fail-direction/impact in both directions): the principle *states* the discipline engine-agnostically, the gate *enforces* it.

Empirically (issue #155 / PR #156), a high-verbosity reviewer — `silent-failure-hunter` — repeatedly over-graded fail-closed, diagnostic-only defects `Critical`/`Important` in a single run; the over-grade gate makes the technical evaluation that catches such labels a recorded, detectable engine step rather than a matter of actor diligence.

## The fix-delta verification gate (Step 3.5) — a complementary, per-iteration check (issue #159)

The shadow pass audits the **whole diff** at **convergence** (and, on an `engine_self_modifying` PR, also once after iteration 1 via the early trigger). That leaves one gap it cannot close cheaply: a regression introduced by **a fix itself**, in the iteration that produced it. A fix is new code; it can ship a fresh `unverified-assumption` / #62/#98 instance — a guard whose accepted-input set is **wider than its downstream consumer's contract**, so it fails open exactly where it claims to fail closed. Caught only by a whole-diff shadow pass, such a regression forces the shadow to *promote* a costly extra iteration (PR #153 took three iterations for one issue because iterations 1–2 each re-introduced a weaker-contract guard in their own fix). **Step 3.5** front-loads that detection: after each iteration's fix commit — **every iteration, unconditionally** — the parent dispatches a **blinded subagent** that re-reviews **only that iteration's cumulative fix delta** (`git diff <iter_fix_base>..HEAD`, the iteration's first-fix parent through HEAD, so an inner re-fix can't split the fix across separately-reviewed commits) plus the consumer code it touches, with the loop's prior findings/fix decisions/fixer reasoning withheld — the same blinding model as the shadow's per-reviewer prompts. Its checks include the #62/#98 operand-contract check (the fix's guard accepted-input set must be a *subset* of its consumer's contract — see the **share-the-contract / parse-don't-validate** principle in `receiving-code-review`) and an adversarial input-shape matrix. A new Critical/Important gate finding first passes the over-grade calibration gate (flag + recorded `severity-calibrated` evaluation, never auto-demote), and a re-affirmed one routes back into the same iteration's fix step (capped at 2 inner attempts, then promoted to a cap-counting iteration; at the cap it rides into the shadow's whole-diff audit and a `## Devflow Reflection` bullet). Like the shadow, the gate and its inner attempts do **not** count toward `max_iterations`, and a gate-subagent failure gets one bounded re-dispatch before the loop records `fix-delta not verified` and proceeds (a deterministic delta-base failure gets a distinct breadcrumb, no retry). The Step 2.6 shadow pass and the post-shadow edit gate are **unchanged** by Step 3.5.

## Non-blocking severity-aware exit in `/devflow:implement` (issue #159)

`/devflow:implement`'s Phase 3.3 used to treat `APPROVE WITH UNRESOLVED SHADOW FINDINGS` (and a non-clean bounded re-review) as a hard **Blocked** stop — aborting the whole lifecycle after the "two consecutive non-clean passes" of the capped run plus its one bounded re-review. That was too aggressive: it discarded a review-ready PR over findings that, after over-grade calibration, are frequently advisory. Phase 3.3 is now **severity-aware**: only a *genuine unresolved Critical* (or an unparseable/ungradeable verdict, fail-closed) takes the Blocked path; a residual of only advisory / Suggestion / `severity-calibrated`-down / deferrable-Important findings **soft-proceeds** — surfaced durably (workpad `### ⚠️ Action required` reflections, and the PR body where a deferrals manifest exists) while the run continues to Phase 4. The PR ships review-ready, not auto-merged; the human merger decides. This preserves the human gate without throwing away completed work over diminishing-returns nits.

### The completeness critic and the mechanism-scoped re-sweep (issue #167)

PR #164 converged to a clean in-loop self-APPROVE, and a later standalone `/devflow:review` flagged two Important findings the loop had missed — both the recurring high-risk classes this section is about: a **vacuous or incomplete audit**, and a **stale comment after a mechanism change**. Two mechanical checks now target them directly. Both are calibrated, not catch-all — read the guarantee-scope paragraphs below for exactly what each does and does not assert.

**The completeness critic (shared engine — `skills/review/SKILL.md`).** When Phase 0.5 classifies the diff as `detect_all_audit` — it adds or changes a scanner / audit / coverage-invariant that *enumerates a population* and *asserts a completeness property* over it — Phase 3.1.5 forces a completeness-critic pass. The pass re-enumerates the audit's target population **by a signal other than the audit's own pattern** and emits a finding for any member of that independent enumeration the audit does not cover. It lives in the shared Phases 0–4.3, so standalone `/devflow:review` and the `/devflow:review-and-fix` fix loop both apply it. It is the engine's answer to the circular-completeness trap: a "detect-all" claim cannot be self-certified by the audit making it — the PR #62 too-narrow tripwire and the PR #154 vacuous drift-guard were both this shape, certified clean by their own output.

*Guarantee scope.* The critic catches an audit that is **not a superset of a genuinely independent enumeration**. **It does not prove the audit is exhaustive:** the independent enumeration is itself reviewer judgment and can share a blind spot with the audit. A clean critic result means "the audit covers everything a second, structurally different enumeration found," not "nothing is uncovered." Like a clean shadow above, it **narrows** the circular-completeness gap; it does not close it.

**The mechanism-scoped self-authored-claim re-sweep (fix loop — `skills/review-and-fix/SKILL.md` Step 3).** After a fix changes a mechanism (a guard, predicate, exclusion, or helper that comments describe), the fix loop re-runs the `devflow:comment-analyzer` agent over **every** comment describing that mechanism — located by the mechanism's identifiers across the touched files, not limited to the fix's own diff hunks — and treats a comment that still describes the pre-change mechanism as a finding. It **reuses the existing comment-analyzer (no new agent)** and lives only in the fix loop, since standalone review applies no fixes — so the shared engine carries no paraphrase of it.

*Guarantee scope.* The re-sweep covers comments describing the **changed** mechanism within the **touched** files. **It is not a repo-wide comment audit:** it does not catch drift in files the fix never touched, nor a claim that names no shared identifier. It closes the "spot-checked the fix's own hunks and missed a stale comment elsewhere in the same file" gap — nothing wider.

## Cost

The shadow pass roughly **doubles** the cost of a converging run — one full engine pass that does
not lead to fixes when it agrees. This is why the `step_2_6` telemetry now carries a full-engine-pass
magnitude (tens of agent calls and a Phase-1+1.5+2+3's worth of tokens) rather than the single call
the old single-subagent design logged; `step_2_6` aggregates the whole parent-run Phases 0–4.3
fan-out. The cost is intentional: it matches the manual `/devflow:review`-after-fix workflow
experienced users already pay (net-zero for them, now mechanical), and it buys a credible audit
rather than a self-check that re-derives the loop's own answer.

One component of that spend was **redundant context transit** the audit did not need: Phase 1's
checklist-generator prompts carried their batch-sliced diff **inline** through the orchestrator's
context on every engine pass — a cost the shadow re-paid on top of every main-pass iteration. That
handoff is now **by file reference** (see the blinding-boundary contract above): Phase 1.1 authors
each batch's slice with a shell-only `awk … >`-redirect over the already-cached `diff.patch`
(reading no `git` objects, so a shallow checkout is unaffected, and taking no *per-file* filename
arguments — its only operand is the fixed run-scoped `diff.patch` path, so no changed-file path is
ever passed and paths with spaces cannot break quoting; a `>`-redirect rather than `| tee`, so the
slice is never echoed to the orchestrator's stdout), and Phase 1.2 passes the generator the slice's
*path*. A guard-class-2 fail-closed fallback preserves coverage in every degraded environment: the
slice is gated on the authoring command's **own exit status** first and a bash-builtin `test -s`
non-empty check second (an `&&`-chain — a size check alone would wave through a non-empty but
**truncated** slice from a partial write, and the batch would review a thinned surface with the
missing files silently unrepresented), and any observable slice-authoring failure — a non-zero
`awk`/redirect exit, or a missing/empty slice from a shallow checkout or a run-id directory hiccup —
routes that batch to the full `diff.patch` path. The residual window is named, not papered over: a
write error `awk` itself neither reports nor exits non-zero on would still yield a truncated slice.
(The fallback covers a *slice-authoring* failure over a populated `diff.patch`; a host with **no**
`awk` at all degrades Phase 0.2's `diff.patch` build first — the whole review, not just the slice —
so that is a different, upstream failure, not one this batch-level fallback masks.) The single-batch
case passes `diff.patch` directly with no slice written. Because `awk`/`test` are already granted in
both cloud allowlists, this adds **no** allowlist entry.

### Non-droppable shadow telemetry, and a promoted-shadow floor

The 2026-07-11 R3 replay study fixed the shadow pass as always-on and identified its licensed lever
as **cost, not existence** — but it had to fight an observability problem: `step_2_6` telemetry
existed in only 20 of 69 runs, and the shadow workpad block itself drops on issue-304-style runs, so
shadow attribution had to be reconstructed from three markers (`loop_role`, `promoted_from_shadow`,
the prior iteration's `promoted_to_iter_next`). The R3 baseline to re-measure against: **12.43M
recorded shadow tokens; 115 shadow-attributable applied fixes across 32 of 69 runs; ~366k tokens per
shadow-attributable Critical/Important fix.**

Two changes make both sides of that ledger recordable instead of reconstructed:

- **The shadow block write is now a single non-optional obligation fused to the pass's
  *termination*, covering *both* termination paths** — Parse-and-compare completion for a full
  fan-out, and the honest-degradation fail-safe for an outcome-3 pass that dies mid-fan-out (which
  writes its `not_verified` block *before* taking outcome 3, rather than dying without writing
  anything — the issue-304 drop shape). It is authored with the Write tool and carries the same
  "mandatory on every pass regardless of how the loop was executed" force as the `iter-<N>.json`
  Layer-1 fused emit. The Decide outcome-1 block-presence read-back gate is unchanged.
- **`lib/efficiency-trace.sh --persist` gains a provenance-gated shadow floor.** A promoted
  successor records `promotion_provenance`: `shadow` recovers a dropped predecessor block with
  promotion credit, `park-calibration-post-shadow` recovers it without promotion credit,
  `park-calibration-pre-shadow` is silent because no predecessor shadow ran, and an unrecognized
  string writes no marker but breadcrumbs the producer typo. Legacy/degraded values retain the floor
  with a hedged `provenance_unestablished` marker. A park-gate promotion never changes a surviving
  predecessor block; future producers must select a defined value to license recovery. The floor
  never writes over an agent-written block. **Stated limitation:** a
  clean outcome-1 shadow whose block dropped leaves no promotion evidence to synthesize from. The
  fused emit is the primary fix and the floor is its backstop, not its equal; the floor recovers
  *attribution*, not shadow-specific cost (this floor recovers no token/wall figures — those are
  captured live by the loop; issue #475's separate Layer-4 execution-file floor records whole-job
  `harness_cost` for writable cloud runs but cannot attribute that cost to the shadow phase). So this
  narrows-the-gap, it does not close it — the shadow still audits its own audit with honest
  calibration.
