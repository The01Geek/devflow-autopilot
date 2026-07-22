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
| **Root** | `skills/create-issue/SKILL.md` | 2,732 | Root ceiling: **2,754 words** |
| **Default path** | root + `step-2-clarify.md` + `step-3-5-steelman.md` + `revision-delta.md` + `step-3-6-audit.md` + `step-4-present-create.md` + `references/issue-template.md` | 31,073 | Default-path ceiling: **31,262 words** |

Each ceiling is at most the implement-time measured value plus **5% headroom** (the AC6 maximum). Both were set from an earlier measurement in this same change and deliberately **not re-raised** when review fixes grew the operands, so the shipped headroom is under 5% on both (root ~0.8%, default path ~0.6%). The suite asserts that legality directly — a ceiling above measured+5% is RED — so a future raise needs a real measurement behind it. The
default-path operand deliberately **excludes the four fallback references** — they load only when
their predicate fires, which is the whole point of the split. `revision-delta.md` is *retained* in the
operand even though it too is predicate-gated (its trigger is any revise-and-re-gate site): a revision
is the common case, so counting it keeps the ceiling conservative rather than flattering.

**The ceilings are ratchet-down-only.** A measured *reduction* lowers the recorded ceiling to the new
measured-plus-5% in the same change; a ceiling is **never raised** to accommodate growth. Growth is
resolved by shedding prose or by moving it behind a load trigger, not by moving the line.

**Every figure on this page is a hand-recorded implement-time snapshot, not a live-rendered value** —
this document has no positional reconciliation against `ci614_words` (contrast the review bundle's
`rb-figure-partition.py` machinery). The suite pins only the two **ceiling** phrases, the
one-directional-ratchet rule stated above, and the `wc -w` ban; it does not re-derive the per-file
table, the overhead itemization, or the conservation delta. So a change that moves any measured figure must re-measure and
re-record it here in the same change — the ceilings will catch growth past the ceiling, but nothing
catches a stale row below it. The two ceilings are checked-in literals under the *enforcement constant*
exemption in `CLAUDE.md`'s prefer-generated-evidence convention (a ceiling **is** the enforcement), and
are mirrored in exactly two places, edited together: the `CI614_ROOT_CEIL` / `CI614_DEFAULT_CEIL`
constants in the contract module, and the two suite pins that assert this document names them.

## Post-split per-file table

Measured at implement time (re-measured 2026-07-21 for issue #709), python3 word-split:

| File | Words | Loaded |
| --- | --- | --- |
| `SKILL.md` (root) | 2,732 | always |
| `references/step-2-clarify.md` | 4,673 | Step 2 entry |
| `references/step-3-5-steelman.md` | 2,133 | Step 3.5 entry |
| `references/revision-delta.md` | 922 | every revision event |
| `references/step-3-6-audit.md` | 8,548 | Step 3.6 entry |
| `references/step-4-present-create.md` | 5,615 | Step 4 entry |
| `references/fallback-no-task-tool.md` | 540 | no usable task-tracking tool |
| `references/fallback-read-only-sandbox.md` | 478 | a `.devflow/tmp/` write is refused |
| `references/fallback-audit-dispatch-arms.md` | 816 | a non-file audit arm, a retry escalation, or no subagent tool |
| `references/fallback-state-owner-unavailable.md` | 814 | the state owner stops answering |
| **root + all 9 references** | **27,271** | — |
| `references/issue-template.md` | 6,450 | Step 3 (unchanged by the split) |
| `references/audit-prompt-template.md` | 2,288 | renderer-owned; carries the issue-#709 `di` dispatch-instruction blocks |

**What the default path sheds.** Before the split every run loaded all 24,473 words of the monolith.
After it, a run on the default path — task tool usable, writable filesystem, file-arm dispatch, state
owner available — never loads the four fallback references: **2,291 words** of predicate-gated prose,
and the always-loaded surface drops from 24,473 to **2,732**.

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

- Post-split total (root + all 9 references), **as measured at the #614 split and frozen here**: **25,814**
- Minus structural overhead: **24,829**
- Pre-split baseline: **24,473**
- **Deviation: +1.45%** — inside the ±2% tolerance.

**These four figures are a frozen past-time snapshot of the #614 split, not live measurements.** They are a registered exemption to the prefer-generated-evidence rule for exactly the reason that rule names: re-rendering them would overwrite the record of what the split conserved and falsify it. The **live** root+references total is the per-file table's bold row above, which the suite reconciles positionally; the ±2% drift band in `lib/test/modules/create-issue-contract.sh` is re-anchored to that live figure whenever a change legitimately moves it (recorded below), so the band keeps catching a silent DROP without freezing the surface at its 2026-07-21 size.

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
