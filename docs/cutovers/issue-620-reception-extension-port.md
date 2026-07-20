---
schema: 1
kind: growth
---

# Issue #620 — reception-extension port and unconditional load

## Files

`.devflow/prompt-extensions/receiving-code-review.md` gains two sections. **Focused test modules
in direct reception passes** ports the module-iteration rule that already governs the loop path,
adapted for direct passes (direct leading-token runner form first, because the local-tier
classifier routinely denies the `bash <path>` wrapper) and explicitly deferring to the
review-and-fix extension's own section on loop runs. **Push form in reception passes** ports the
explicit-destination-ref rule and names the two non-conforming forms with their rationales,
including the operator record that `git push -u origin <branch>` has pushed straight to main from
a `.claude/worktrees/` checkout under `push.default=upstream`.

`skills/review-and-fix/SKILL.md` gains a second `load-prompt-extension.sh` call and the scoping
prose that governs how loop runs consume the loaded text — reference resolution, non-binding
interactive directives, and the supersession-authority guard.

This extension is now **mandatory prompt surface**: it loads on every `/devflow:review-and-fix`
entry that goes through the skill preamble — the standalone loop, the implement Phase 3 inline
run, and the Step 2.6 shadow entry. The documented Skill-denied fallback, where Phase 3 reads the
engine straight from the tree, bypasses the preamble and is unchanged by this issue. The vendored
`skills/receiving-code-review/SKILL.md` stays repo-agnostic and is unchanged; the sources of
record (`.devflow/prompt-extensions/review-and-fix.md`'s focused-modules section and
`skills/review-and-fix/references/fixing.md` Step 3 item 6) are unchanged.

## Justification

Both rules were already proven, codified, and tested on the fix-loop path, and both were being
re-derived per reception pass: repeated full-suite runs to read back a handful of figures, and
stranded or misdirected pushes from shepherd worktrees. Porting them costs bytes once; the
alternative — per-rule byte-mirroring into the already-loaded review-and-fix extension — delivers
today's two rules at zero new load but leaves every future reception rule dependent on a manual
mirror decision, which is the silent-absence failure this change exists to close.

The load is unconditional rather than gated because a conditional load reintroduces exactly that
failure: a rule that reaches the loop only when someone remembers to route it there.

## Bounded-growth target

The issue set a target of 450 `_raf_words` for the two new sections plus the scoping prose. The
shipped prose measures **599** after three compression passes from an initial 649 — including a
late correctness addition the operand-trace sweep required (the supersession policy needed a
named producer for its authority operand and a route for the unestablished case), which was paid
for by trimming connective tissue rather than by re-pegging the target. Every remaining clause is mandated by AC1, AC2,
AC4 or AC12's at-minimum lists, so 450 is not reachable without dropping mandated content; the
target was reconciled once to **600** under the implement skill's Phase 2.2.6 rule, preserving the
property the target exists for — a recorded, justified, falsifiable number the review gate can
fail an addition against. Its magnitude was set to 600 — ten words above the 590 measured when
the target was reconciled, and one above the 599 finally shipped. The
rationale is recorded in the issue workpad as an AC-rewrite note and as an `issue-accuracy`
reflection.

## Budget renegotiation

Issue #620 widens two measures, not merely their ceilings: the receiving extension is now part of
the always-loaded surface, so the **initial-load** and **max-active-step** measures became
three-term sums.

| Quantity | Before | After | Ceiling before → after |
| --- | ---: | ---: | --- |
| Plugin root | 3,213 | 3,464 | 3,500 → 3,500 (unchanged) |
| Initial load | 5,686 (root + extension) | 7,370 (root + both extensions) | 5,690 → 7,374 |
| Max active step | 16,948 | 18,632 | 17,000 → 18,636 |

The root ceiling was deliberately **not** renegotiated: the scoping prose fits under it with 36
words to spare, which makes the root the tightest budget in the table and is recorded as such in
`docs/review-and-fix-budget.md`'s maintainer note. Each renegotiated ceiling carries roughly four
words of headroom over its measurement, following the precedent set by issues #556 and #619 — a
ceiling set exactly at the measurement makes the next one-sentence edit a budget breach.

The **cumulative-path** and **growth-delta** arithmetic deliberately excludes the receiving
extension. Those figures isolate the #530 split against a frozen pre-split monolith basis that
never loaded this file, so folding it in would pollute the comparison rather than measure the
split. The exclusion is stated in the budget doc's Counting method and in the `#530 budget` block
in `lib/test/run.sh`. The cumulative and growth figures still move (43,248 and +4,574) because the
root itself grew by the loader call and its scoping prose.

Growth is bounded by design: the two new sections state rules and cite their sources of record
rather than restating them, and neither duplicates an artifact or module inventory into prose.
