---
bump: patch
type: Changed
---

- **A direct `/devflow:receiving-code-review` pass now inherits the editor-authority guard.**
  The rule that weighs an issue Addendum's authority by the editor's repository permission —
  added for the fix loop in #620 — moved from `skills/review-and-fix/SKILL.md` into
  `.devflow/prompt-extensions/receiving-code-review.md`, so both a standalone reception pass and
  the fix loop apply it. The review-and-fix root keeps only the loop-specific tail (routing
  conflicting findings to the loop's deferral channel). (#658)
