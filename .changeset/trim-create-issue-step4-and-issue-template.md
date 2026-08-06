---
bump: patch
type: Changed
---

- **Editorially compressed `/prflow:create-issue`'s Step 4 and issue-template references.**
  `skills/create-issue/references/step-4-present-create.md` and `references/issue-template.md`
  lose the rationale wrapped around their instructions — objection/rebuttal blocks, historical
  archaeology, anti-refactor asides and maintainer notes — under `CLAUDE.md`'s
  instruction-plus-consequence prose rule, while the instructions, prohibitions, degraded arms
  and exact command forms they govern stay. Three statements are additionally **corrected**
  rather than only shortened: the acceptance-criteria block-prose rule now states both outcomes
  `scripts/section_parse.py` actually produces for prose placed after the criteria (dropped when
  a blank line separates it, welded onto the last criterion only when it is indented and abuts
  it); the `bound=none` draft-root fallback is stated in full at each write site instead of
  pointing at a variable bound in an earlier turn; and Move 2a's "claim to verify, not an
  attestation to accept" property is scoped to exclude Step 3.6's degraded inline arm, where it
  does not hold. `step-4-present-create.md` also gains a sub-step index and three sub-headings,
  splitting a body that previously carried a single heading. (#1371)
