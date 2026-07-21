# `/devflow:create-issue` prompt budget

`skills/create-issue/SKILL.md` is a thin always-loaded **root** plus marker-gated **references**
under `skills/create-issue/references/` (issue #614) — the third instance of the repo's
progressive-disclosure pattern, after the `/devflow:implement` `phases/` split and the #529 review
bundle. This document is the record of every live measured figure and of the decisions behind the
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
| **Root** | `skills/create-issue/SKILL.md` | 2,623 | Root ceiling: **2,754 words** |
| **Default path** | root + `step-2-clarify.md` + `step-3-5-steelman.md` + `revision-delta.md` + `step-3-6-audit.md` + `step-4-present-create.md` + `references/issue-template.md` | 29,774 | Default-path ceiling: **31,262 words** |

Each ceiling is the implement-time measured value plus **5% headroom** (the AC6 maximum). The
default-path operand deliberately **excludes the four fallback references** — they load only when
their predicate fires, which is the whole point of the split.

**The ceilings are ratchet-down-only.** A measured *reduction* lowers the recorded ceiling to the new
measured-plus-5% in the same change; a ceiling is **never raised** to accommodate growth. Growth is
resolved by shedding prose or by moving it behind a load trigger, not by moving the line.

The two ceiling literals are the only checked-in numbers this document does not render live, because a
ceiling **is** the enforcement — the *enforcement constant* exemption in `CLAUDE.md`'s
prefer-generated-evidence convention. They are mirrored in exactly two places, edited together: the
`CI614_ROOT_CEIL` / `CI614_DEFAULT_CEIL` constants in the contract module, and the two suite pins that
assert this document names them.

## Post-split per-file table

Measured at implement time (2026-07-21), python3 word-split:

| File | Words | Loaded |
| --- | --- | --- |
| `SKILL.md` (root) | 2,623 | always |
| `references/step-2-clarify.md` | 4,673 | Step 2 entry |
| `references/step-3-5-steelman.md` | 2,133 | Step 3.5 entry |
| `references/revision-delta.md` | 922 | every revision event |
| `references/step-3-6-audit.md` | 7,663 | Step 3.6 entry |
| `references/step-4-present-create.md` | 5,310 | Step 4 entry |
| `references/fallback-no-task-tool.md` | 540 | no usable task-tracking tool |
| `references/fallback-read-only-sandbox.md` | 334 | a `.devflow/tmp/` write is refused |
| `references/fallback-audit-dispatch-arms.md` | 669 | a non-file audit arm, a retry escalation, or no subagent tool |
| `references/fallback-state-owner-unavailable.md` | 748 | the state owner stops answering |
| **root + all 9 references** | **25,615** | — |
| `references/issue-template.md` | 6,450 | Step 3 (unchanged by the split) |
| `references/audit-prompt-template.md` | 1,515 | renderer-owned (unchanged by the split) |

**What the default path sheds.** Before the split every run loaded all 24,473 words of the monolith.
After it, a run on the default path — task tool usable, writable filesystem, file-arm dispatch, state
owner available — never loads the four fallback references: **2,291 words** of predicate-gated prose,
and the always-loaded surface drops from 24,473 to **2,623**.

## Conservation check

The split must not silently shed unpinned contract prose, and the structural additions it is *required*
to make must not be able to force the check to fail. So the conserved operand is the post-split total
minus the itemized structural overhead:

| Overhead category | Words |
| --- | --- |
| Boundary marker lines (18 markers, 9 files) | 108 |
| The root's routing table | 325 |
| The root's entry-gate prose | 155 |
| The root's non-degradable-invariants block | 175 |
| Seam-splice pointer sentences | 222 |
| **Total structural overhead** | **985** |

- Post-split total (root + all 9 references): **25,615**
- Minus structural overhead: **24,630**
- Pre-split baseline: **24,473**
- **Deviation: +0.64%** — inside the ±2% tolerance.

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

- **2026-07-21 (issue #614) — initial ceilings set.** Root 2,623 → ceiling 2,754. Default path 29,774
  → ceiling 31,262. Conservation +0.64% against the implement-time baseline of 24,473. Both stale-figure
  corrections above recorded at the same time.

When a later change re-measures, append a row here rather than editing an earlier one: the record is
the history of what the surface cost, and overwriting it loses exactly the drift a budget exists to catch.
