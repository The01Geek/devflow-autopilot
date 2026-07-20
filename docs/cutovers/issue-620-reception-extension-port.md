---
schema: 1
kind: growth
---

# Issue #620 — reception-extension port and unconditional load

## Files

`.devflow/prompt-extensions/receiving-code-review.md` gains two sections. **Focused test modules
in direct reception passes** ports the module-iteration rule that already governs the loop path,
adapted for direct passes (the direct leading-token runner form leads) and deferring to the
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

The issue targeted 450 `_raf_words` for the two new sections plus the scoping prose.
**Shipped: 626.** The target was renegotiated twice, and both moves are recorded here rather than
folded away, because a bound that silently tracks its subject has stopped bounding anything.

1. **450 → 600.** The prose reached 590 after two compression passes from 649, and every remaining
   clause is mandated by AC1, AC2, AC4 or AC12's at-minimum lists — 450 is unreachable without
   dropping mandated content. Reconciled under the implement skill's Phase 2.2.6 rule; recorded in
   the issue workpad as an AC-rewrite note and an `issue-accuracy` reflection.
2. **600 → 630, for a correctness fix.** The external `writing-skills` RED/GREEN pass this
   repo's prompt-surface routing mandates found that the supersession guard named an operand it
   could not obtain: it keyed authority on the *editor's* `author_association`, but GitHub exposes
   no association for an edit — `gh issue view --json` has no such field at all, and the REST
   payload's `author_association` describes the **issue author**. Verified directly against the
   live API. As written the write-permission arm was dead and every run would have taken the safe
   arm silently — the operand-trace defect class, in the very prose that adds a guard. The fix
   names the retrievable call, states whose association the field actually is, and routes the
   third-party-editor case to the unestablished arm. It cost 36 words after compression.

The second move is a deliberate choice to let correctness win over a word target. The **root
ceiling was not** renegotiated to absorb it: the scoping prose was compressed instead, leaving the
root at 3,493 of 3,500 — a **7-word margin**, now by far the tightest budget in
`docs/review-and-fix-budget.md`, and the real constraint any future addition to this preamble
meets first.

## Budget renegotiation

The receiving extension is now always-loaded, so the **initial-load** and **max-active-step**
measures became three-term sums.

| Quantity | Before | After | Ceiling before → after |
| --- | ---: | ---: | --- |
| Plugin root | 3,213 | 3,493 | 3,500 → 3,500 (unchanged) |
| Initial load | 5,686 (root + extension) | 7,397 (root + always-loaded extensions) | 5,690 → 7,401 |
| Max active step | 16,948 | 18,659 | 17,000 → 18,663 |

The scoping prose fits under the unchanged root ceiling with 7 words to spare, which makes the
root the tightest budget in the table — recorded as such in `docs/review-and-fix-budget.md`'s
maintainer note. Each renegotiated ceiling carries roughly four words of headroom over its
measurement, following issues #556 and #619 — a ceiling set exactly at the measurement makes the
next one-sentence edit a budget breach.

The **cumulative-path** and **growth-delta** arithmetic excludes the receiving extension —
rationale in the budget doc's Counting method, mirrored in `lib/test/run.sh`'s `#530 budget`
block. Those figures still move (43,277 and +4,603) because the root itself grew by the loader
call and its scoping prose.

Growth is bounded by design: the two new sections state rules and cite their sources of record
rather than restating them, and neither duplicates an artifact or module inventory into prose.
