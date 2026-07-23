# `/devflow:create-issue` prompt budget

`skills/create-issue/SKILL.md` is a thin always-loaded **root** plus marker-gated **references**
under `skills/create-issue/references/` (issue #614) — another instance of the repo's
progressive-disclosure pattern, alongside the `/devflow:implement` `phases/` split, the #529 review
bundle, and the #530 fix-loop references. This document is the record of every measured figure and of the decisions behind the
two ceilings the suite enforces. It is the sibling of [`review-bundle-budget.md`](review-bundle-budget.md).

## How these figures are measured

Every word count on this page is produced by **python3 word-splitting** — `len(open(p).read().split())`
— which is exactly what `lib/test/modules/create-issue-contract.sh`'s `ci614_words` helper runs.

**Never `wc -w`.** GNU and BSD `wc -w` disagree in two directions on this repo's prompt corpus, and no
locale setting reconciles them: under `LC_ALL=C` GNU drops a standalone non-ASCII token (every spaced
` — `, ` → `) entirely, while under a UTF-8 locale BSD splits `rc≠0` on the `≠`. A `wc`-derived figure
measures the bundle *plus the host*, so it passes at one desk and fails at another — the defect class
recorded in `CLAUDE.md`'s review-bundle gotcha, and the motivating case for the create-issue extension's
**Measurement-command naming** evidence axis.

Reproduce any figure below with:

```bash
python3 -c 'import sys; print(sum(len(open(p).read().split()) for p in sys.argv[1:]))' <files…>
```

## The two enforced ceilings

Both are asserted by `lib/test/modules/create-issue-contract.sh` (driven by the required
`lib + python tests` CI job) and report **RED on exceed**.

| Ceiling | Operand | Measured | Enforced ceiling |
| --- | --- | --- | --- |
| **Root** | `skills/create-issue/SKILL.md` | 3,207 | Root ceiling: **3,527 words** |
| **Default path** | root + `step-2-clarify.md` + `step-3-5-steelman.md` + `revision-delta.md` + `step-3-6-audit.md` + `step-4-present-create.md` + `references/issue-template.md` | 35,100 | Default-path ceiling: **38,042 words** |

Each ceiling is at most the implement-time measured value plus **10% headroom**, widened from 5% by the issue-#749 renegotiation recorded below after successive intentional additions collided with the line on nearly every PR. The suite asserts that legality directly — a ceiling above measured+10% is RED — so a raise still needs a real measurement behind it, and the band bounds how much unmeasured growth a raise can pre-authorize. The
default-path operand also deliberately **excludes `skills/docs-verify/SKILL.md`**, which Step 1 loads on every
default-path run: it is *dispatched into a peer's context* and never read into the orchestrator's, so
its words cost the caller's prompt nothing and counting them here would misreport the budget these
ceilings exist to bound (its byte row is tracked instead by `lib/test/prompt-mass-baseline.json`). The
operand deliberately **excludes the four fallback references** — they load only when
their predicate fires, which is the whole point of the split. `revision-delta.md` is *retained* in the
operand even though it too is predicate-gated (its trigger is any revise-and-re-gate site): a revision
is the common case, so counting it keeps the ceiling conservative rather than flattering.

**The ceilings are ratchet-down-only by default.** A measured *reduction* lowers the recorded ceiling to
the new measured-plus-10% in the same change. Ordinary growth is resolved by shedding prose or by moving
it behind a load trigger, not by moving the line: a raise is **never** an ordinary re-measure. It is an
explicit human renegotiation, made only when the shedding arithmetic provably does not close, and it is
recorded as its own decision-record entry below naming who authorized it.

**Every figure on this page is a hand-recorded implement-time snapshot except the two the suite
reconciles positionally** — the recorded **root** measurement and the recorded **root + all 9
references** total are each compared against a live `ci614_words` count, so a stale value in either
goes RED. The rest of the page carries no such reconciliation (contrast the review bundle's
`rb-figure-partition.py` machinery, which partitions *every* governed figure): beyond those two
figures the suite pins only the two **ceiling** phrases, the one-directional-ratchet rule stated
above, and the `wc -w` ban; it does not re-derive the per-file table, the overhead itemization, or
the conservation delta. So a change that moves any measured figure must re-measure and
re-record it here in the same change — the ceilings will catch growth past the ceiling, but nothing
catches a stale row below it. The two ceilings are checked-in literals under the *enforcement constant*
exemption in `CLAUDE.md`'s prefer-generated-evidence convention (a ceiling **is** the enforcement), and
are mirrored in exactly two places, edited together: the `CI614_ROOT_CEIL` / `CI614_DEFAULT_CEIL`
constants in the contract module, and the two suite pins that assert this document names them.

## Post-split per-file table

Live figures (python3 word-split). Rows are re-measured whenever a change moves them — see
the decision record below for when each was last re-measured:

| File | Words | Loaded |
| --- | --- | --- |
| `SKILL.md` (root) | 3,207 | always |
| `references/step-2-clarify.md` | 4,843 | Step 2 entry |
| `references/step-3-5-steelman.md` | 2,237 | Step 3.5 entry |
| `references/revision-delta.md` | 986 | every revision event |
| `references/step-3-6-audit.md` | 10,959 | Step 3.6 entry |
| `references/step-4-present-create.md` | 5,863 | Step 4 entry |
| `references/fallback-no-task-tool.md` | 540 | no usable task-tracking tool |
| `references/fallback-read-only-sandbox.md` | 772 | a `.devflow/tmp/` write is refused |
| `references/fallback-audit-dispatch-arms.md` | 827 | a non-file audit arm, a retry escalation, or no subagent tool |
| `references/fallback-state-owner-unavailable.md` | 880 | the state owner stops answering |
| **root + all 9 references** | **31,154** | — |
| `references/issue-template.md` | 7,005 | Step 3 (unchanged by the split) |
| `references/audit-prompt-template.md` | 3,118 | renderer-owned; carries the issue-#708 enumerate-dimensions checklist and the issue-#709 `di` dispatch-instruction blocks |

**What the default path sheds.** Before the split every run loaded all 24,473 words of the monolith.
After it, a run on the default path — task tool usable, writable filesystem, file-arm dispatch, state
owner available — never loads the four fallback references: **3,059 words** of predicate-gated prose,
and the always-loaded surface drops from 24,473 to **3,207**.

## Conservation check

The split must not silently shed unpinned contract prose, and the structural additions it is *required*
to make must not be able to force the check to fail. So the conserved operand is the post-split total
minus the itemized structural overhead:

| Overhead category | Words | How to re-derive it |
| --- | --- | --- |
| Boundary marker lines (two per gated reference) | 108 | first + last line of each `references/*.md` except the two templates |
| The root's routing table | 325 | the `\| Load trigger \|` table through the following blank line |
| The root's entry-gate prose | 155 | `## Reference routing` heading to the table |
| The root's non-degradable-invariants block | 175 | `## Non-degradable invariants` to `## Steps` |
| Seam-splice pointer sentences | 222 | standalone pointer lines naming the routing table or a fallback reference |
| **Total structural overhead** | **985** | — |

**The seam-pointer row counts standalone pointer lines only.** A pointer spliced mid-paragraph — the
Step 4 presentation gate's is one — is not counted, so this row **understates** the true structural
overhead. That direction is deliberate and fail-safe: understating overhead leaves a larger residue in
the conserved operand, which can only make the ±2% check *harder* to pass, never easier. A future
re-measure that wants the tighter figure should count the spliced pointers too and record the change here.

This arithmetic is a **frozen past-time snapshot of the #614 split**, not a live measurement:
it answers "did the re-partition lose prose?", which is a question about one historical change.
Re-rendering it against a later total would destroy exactly the record it exists to keep, so it
is never machine-reconciled (the #656 snapshot exemption).

- Post-split total (root + all 9 references), at the split: **25,814**
- Minus structural overhead: **24,829**
- Pre-split baseline: **24,473**
- **Deviation: +1.45%** — inside the ±2% tolerance.

The **live** root+references total is the table row above, reconciled positionally against the
suite's own measurement (`CI614_TOTAL_RECORDED` in `lib/test/modules/create-issue-contract.sh`,
a coupled pair edited together). It sits above the frozen figure because later changes have
**added** prose deliberately — growth authored on purpose is not the silent drop the ±2%
conservation band exists to catch, which is why that band tracks the recorded total rather than
this frozen split baseline.

**Issue #705's addition is the worked example of that.** #705 added the *Staged canonical-draft
write* shared procedure and the staged-artifact enumeration entries — new contract prose authored
on purpose, not a shed — and the recorded total was re-centred on the new measurement rather than
read as a conservation failure.

### Two recorded corrections to the issue's stated figures

1. **The baseline.** Issue #614 states a pre-split baseline of **21,704 words**, measured when the
   issue was drafted. The file grew between drafting and implementation: at implement time
   `git show HEAD:skills/create-issue/SKILL.md` measures **24,473 words** by the same counter. The
   conservation check above is anchored to the re-measured implement-time baseline, because comparing
   a post-split total against a stale pre-split figure would report a ~13% "loss" that never happened.
   This is precisely the measurement-rot class the new **Measurement-command naming** evidence axis
   (AC13) was added to prevent, arriving in the same change that demonstrates it.

2. **The conservation operand.** AC6 specifies the operand as *root + all 9 references +
   `issue-template.md`*, compared against a baseline that is `SKILL.md`'s word count alone. Those two
   are not commensurable: AC1 holds `issue-template.md` byte-unchanged, so it contributes 6,450 words
   to the post-split side of a comparison whose pre-split side never contained it — the check could
   only ever fail, by construction. The operand recorded above is therefore *root + all 9 references*,
   which is exactly the surface the split moved. `issue-template.md` remains in the **default-path
   ceiling** operand, where it belongs (the default path really does read it).

## Decision record

- **2026-07-21 (issue #614) — initial ceilings set.** Root 2,732 → ceiling 2,754. Default path 29,973
  → ceiling 31,262. Both ceilings were set from earlier measurements in this same change and left
  unraised as review fixes grew the operands, so the shipped headroom is below the 5% maximum on
  both. Conservation +1.45%
  against the implement-time baseline of 24,473. Both stale-figure corrections above recorded at the
  same time. The ratchet rule binds every *subsequent* change; these initial values are set from the
  final pre-merge measurement.

- **2026-07-22 (issue #705) — staged canonical-draft write added.** Added the *Staged canonical-draft write*
  shared procedure and the staged-artifact enumeration entries, raising the root-plus-references total
  25,814 → **27,198** and the default-path measured 29,973 → **31,202** (ceiling unchanged at 31,262, ~0.2%
  headroom). Root unchanged at 2,732. `CI614_TOTAL_RECORDED` re-recorded 25,814 → 27,198. No ceiling raised.
  (The figures are the final pre-merge measurement: a review fix re-anchored the write-landing
  confirmation prose off the retired delete step, moving both totals by one word.)

- **2026-07-21 (issue #704) — evidence-provenance prose added; ceilings UNCHANGED.** Default path
  29,973 → **31,085** (+1,112: the claim-class enumeration and baseline convention in
  `issue-template.md`, the proportionate-verification and finding-evidence policy in
  `step-3-6-audit.md`, and the two thin staleness hooks in `step-3-5-steelman.md` and
  `revision-delta.md`). The root is **untouched at 2,732** — it had 22 words of headroom, so the
  change deliberately placed no prose there. Neither ceiling is raised: the ratchet is
  down-only, and the growth was absorbed within the existing default-path headroom, which now
  stands at 177 words (~0.6%). The review round then added the reconciled multi-line-query
  contract statement and the proportionate-verification wiring, which is included in this figure. The auditor's new reproducible-evidence bar was placed in
  `references/audit-prompt-template.md`, which is **not** in either budgeted operand, precisely so
  the bar could be stated in full without spending default-path headroom.

- **2026-07-22 (PR #706 review round) — review fixes re-measured; ceilings UNCHANGED.** Default path
  31,085 → **31,196** (+111), conservation total 26,580 → **26,691** (+111, the same prose: it lands
  entirely in the budgeted step references). The three edits are all review-finding fixes, not new
  feature prose: `step-3-6-audit.md` (+76) gained the `unestablished`-counts-as-missing rule, the
  read-a-line-by-its-JSON-quoting rule that replaced an overstated forge-proof absolute, and the
  baseline-conflict comparison the *full independent verification* arm previously named without a
  mechanism; `revision-delta.md` (+23) and `step-3-5-steelman.md` (+12) replaced a staleness verdict
  list that named `unestablished` — a token the tool's closed `fresh`/`stale`/`possibly-stale`
  vocabulary never prints as a `state=` — with the vocabulary the tool actually reports. The root is
  again **untouched at 2,732**. Neither ceiling is raised (the ratchet is down-only); default-path
  headroom narrows to **66 words (~0.2%)**, which is the remaining budget a further change must fit
  or shed prose to make room for.

- **2026-07-22 (PR #706 review round 3) — a further review round; ceilings UNCHANGED.** Default
  path 31,196 → **31,252** (+56), conservation 26,691 → **26,747**. The additions state the
  `--domain-stdin` class split at the three sites that consult `check-claim-staleness`: a count or
  inventory claim that does not pipe its re-executed full-domain search can only ever answer
  `possibly-stale reason=domain-not-recomputed`, so every consuming site previously documented a
  command that made the feature's own headline benefit unreachable for two of the three claim
  classes. The first draft of this fix measured 31,274 — **12 words over the ceiling** — and was
  **shed to fit rather than accommodated by a raise** (the two sibling sites were reduced to a
  parenthetical pointing at the primary statement in `step-3-6-audit.md`): the ratchet is
  down-only, and this is what that rule looks like when it binds. Remaining default-path headroom
  is **10 words (~0.03%)** — the next change to a budgeted member almost certainly has to shed
  prose to fit, which is the signal to re-partition rather than to renegotiate the ceiling.

- **2026-07-22 (PR #706 shadow round) — the audit run's opening MOVED; ceilings UNCHANGED.** A
  blinded shadow review found the claim-baseline convention inert on its documented path: `init`
  mints the nonce and creates the state file, and it was instructed only at Step 3.6 — after the
  Step 3 and Step 3.5 sites that record and consume baselines — so every baseline call exited
  non-zero with no state file and the whole mechanism shipped dead. The nonce/`init` block therefore
  **moved** from `step-3-6-audit.md` (−104) to `issue-template.md` (+136, the move plus the
  `claim=` key citation the consumers need to join on), with `step-3-6-audit.md` keeping a pointer
  and a no-state fallback. Default path 31,252 → **31,246**; conservation 26,747 → **26,605**.
  The first draft of this round measured **31,503 — 241 words over the ceiling**, and was brought
  under by shedding, not by raising: the verdict-vocabulary gloss was reduced to one statement
  instead of three copies, and this PR's own earlier review-round prose was compressed to its
  operative core. Headroom is **16 words (~0.05%)**. Both ceilings are untouched.

- **2026-07-22 (PR #706 merge with `main`) — a MERGE-COLLISION ceiling re-record; the ratchet is
  suspended for this one event and resumes immediately.** Merging `main` into this branch brings
  together two growths that were each authored *within their own branch's headroom* and neither of
  which exceeded the ceiling alone: #705's staged canonical-draft write (default path 29,973 →
  31,202 on `main`) and #704's evidence-provenance prose (29,973 → 31,246 on this branch). Their
  union measures **32,475** — 1,213 over the 31,262 ceiling — and no single change is responsible
  for the overrun, so there is no change to shed prose *from*. The ceiling is therefore re-recorded
  to **32,491** (measured + a 16-word margin, far inside the AC6 measured-plus-5% legality bound),
  and the conservation figure `CI614_TOTAL_RECORDED` is re-centred 26,605/27,198 → **27,989**. This
  is a deliberate, human-authorized departure from the one-directional ratchet stated above, recorded here so it
  is auditable rather than silent; it is **not** a precedent for accommodating growth inside a
  single change, where the rule binds unchanged. Root is untouched at **2,732**. Headroom is 16
  words (~0.05%).

- **2026-07-22 (PR #728, issue #708) — MERGE-COLLISION ceiling re-record, at the operator's
  direction set to the full AC6 maximum.** #708's Step 3.6 per-dimension coverage procedure was
  authored inside its own branch's headroom (default path landed at exactly **31,262**, the
  then-ceiling). Merging `main` brought in the #704/#706 union that had already re-recorded the
  ceiling to 32,491 with 16 words of headroom, and the two measure **32,619** together — the same
  merge-collision class the row above describes, where no single change is responsible for the
  overrun. Rather than another 16-word margin that the next PR collides with immediately, the
  operator authorized the **full measured-plus-5% AC6 maximum**: the ceiling is re-recorded to
  **34,249** (measured 32,619 + 5%), and `CI614_TOTAL_RECORDED` is re-centred 27,989 → **28,133**.
  Root is untouched at **2,732**. This is a deliberate, human-authorized departure from the
  one-directional ratchet, recorded here so it is auditable rather than silent; the ratchet
  resumes immediately, and it remains **not** a precedent for accommodating growth inside a
  single change. Headroom is now ~5%.

- **2026-07-22 (PR #732, issue #729) — conservation figure re-centred; both ceilings untouched.**
  #729 makes the Step 3.6 audit dimensions declared data rather than a scrape of rendered prose.
  One default-path member grows: `step-3-6-audit.md` (+49 words) gains the degraded arm for an
  enumeration that now exits non-zero on a malformed declaration (a failure mode that previously
  had no rule). The audit template also grows, but it is renderer-owned and sits outside the
  default-path operand, so it moves neither ceiling. Default path measures **32,668**
  against the unchanged **34,249** ceiling, and root is unchanged at **2,732** against **2,754** —
  so neither ceiling moves and the ratchet is not touched. Only `CI614_TOTAL_RECORDED`, the
  two-sided conservation band, is re-centred 28,133 → **28,182** (+49 words, ~0.2%, well inside the
  ±2% band it was already passing) so the doc's recorded total keeps matching the live count.

When a later change re-measures, append a row here rather than editing an earlier one: the record is
the history of what the surface cost, and overwriting it loses exactly the drift a budget exists to catch.

- **2026-07-21 (issue #709) — dispatch-instruction generator; no ceiling renegotiation.** The
  canonical audit-dispatch instructions moved out of `step-3-6-audit.md`'s freehand arm-(i)
  preamble-composition prose and into `render-audit-prompt.py`'s `dispatch-instructions` mode,
  rendered from new `di` blocks in `audit-prompt-template.md` — which is renderer-owned and sits
  outside **both** budget operands, so the bulk of the new prose costs the default path nothing.
  What did land on the default path is the invocation contract, the withhold-then-disclose contract,
  and the honest-limits statement: default path 29,973 → **31,073**, root unchanged at **2,732**.
  **Neither ceiling moved** — 31,073 is under the 31,262 default ceiling and inside its ≤5%
  ratchet-legality band, and the root did not change — so this is an ordinary re-measure, not a
  ceiling renegotiation, and `CLAUDE.md` is untouched. The `CI614_TOTAL_RECORDED` conservation
  anchor was re-anchored 25,814 → **27,271** (the live root+references total) so the ±2% band keeps
  guarding against a silent prose drop from the new size rather than reporting this change's
  intended growth as drift.

- **2026-07-22 (the #705 + #709 merge) — default-path ceiling renegotiated.** Merging issue #705's
  staged-canonical-draft prose with issue #709's dispatch-instruction prose put the default path at
  **32,302 words** — each change fit under the 31,262 ceiling alone, their union did not. The
  one-directional ratchet stated above was suspended for this single raise by explicit human decision, on the ground
  that successive intentional feature additions were colliding with a ceiling set at ~0.6% headroom.
  The new ceiling is the AC6 **maximum**: measured 32,302 plus the full 5% headroom = **33,917**.
  Root unchanged at 2,732 (ceiling 2,754). `CI614_TOTAL_RECORDED` re-anchored to **28,655** (the live
  root+references total, carrying both changes' prose plus the merge's staged-artifact addition to
  the #709 out-of-bounds block). That rule binds again from here — a measured reduction lowers
  this figure.

- **2026-07-22 (the #704 + #716 merge into the same branch) — re-measure only, no ceiling move.**
  Merging main's issue-#704 (baseline-grounded claim provenance) and issue-#550 work into the
  already-merged #705 + #709 branch raised the default path 32,302 → **33,575** and the
  root-plus-references total 28,655 → **29,446** (`CI614_TOTAL_RECORDED` re-anchored to match).
  **No ceiling moved:** 33,575 is under the 33,917 set in the entry above and well inside its
  ≤5% legality band, so the raise granted there absorbed this growth rather than needing a second
  renegotiation. The shipped default-path headroom is now ~1.0%. Root unchanged at 2,732.

- **2026-07-22 (the #729 merge into main) — re-measure only, no ceiling move.** Merging issue #729's
  declared-dimension-key work with the issue-#709 dispatch-instruction prose that landed on main
  during the run moved the default path to **33,768 words** and the root-plus-references total to
  **29,639** (`CI614_TOTAL_RECORDED` re-anchored 29,590 → 29,639). **No ceiling moved:** 33,768 is
  under the 33,917 set two entries above and well inside its ≤5% legality band, so this is an
  ordinary re-measure, not a renegotiation, and `CLAUDE.md` is untouched. Shipped default-path
  headroom is **149 words (~0.44%)**. Root unchanged at **2,732** (ceiling 2,754). #729's own prose
  is deliberately concentrated in `audit-prompt-template.md` (renderer-owned, outside both operands,
  +2,941 bytes); what reached a budgeted member is `step-3-6-audit.md`'s degraded-arm route for a
  non-zero `enumerate-dimensions` exit (+295 bytes), recorded in
  `docs/cutovers/issue-729-declared-dimension-keys-growth.md`.

- **2026-07-23 (issue #749) — BOTH ceilings renegotiated, and the legality band widened 5% → 10%.**
  Right-sizing Step 1 into a two-arm, duty-floor-bounded pass put root-resident obligations on the
  orchestrator that no reference can own: the arm-selection pre-pass, the disjoint-leg partition and
  its reconciliation, the three `.docs.internal` degenerate cases, the unequal-return degradation, the
  escalation-only verdict role, the slug binding and run pointer, and the degraded arm. Those cost
  **627 words** written telegraphically and replaced **96**; genuinely superseded root prose totalled
  only ~190, and the remainder is decision-owning prose with no sole tested owner, so the prose-cutover
  convention forbids deleting it. The arithmetic did not close, and the run stopped Blocked rather than
  pick a remedy silently. **The human requester authorized the raise** and, seeing that the previous
  5% band had been consumed to ~0.4% within three merges, widened the band itself to **10%** so the
  ceiling stops being re-collided with on nearly every PR. Root **2,732 → 3,207** measured, ceiling
  2,754 → **3,527**; default path **33,768 → 35,100** measured (34,584 before the branch was rebased onto main's
  concurrently-landed prose), ceiling 33,917 → **38,042**. The root ceiling is measured-plus-10%
  exactly; the default-path ceiling was set from the pre-rebase measurement and deliberately not
  re-raised afterwards, so its shipped headroom is ~8.4% rather than the full band.
  `CI614_TOTAL_RECORDED` re-anchored 29,639 → **31,154**. The two ratchet
  -legality assertions in the contract module move 105 → 110 in the same commit. The one-directional
  rule binds again from here — a measured reduction lowers these figures.
