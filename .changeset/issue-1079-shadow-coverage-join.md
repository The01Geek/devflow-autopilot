---
bump: patch
type: Fixed
---

- **Specify the per-reviewer assessment operand the shadow coverage join reads.** The shadow
  pass's 1:1 coverage join referred to "the per-reviewer assessment captured in 'Parse and
  compare'", but that section described no capture step, so the fail-closed join operand was
  incidental — held only by an orchestrator that still carried the raw reviewer returns in
  context, and lost on a compacted or resumed run. `skills/review-and-fix/references/shadow-review.md`
  now describes capturing, per dispatched reviewer, the positive-return assessment/verdict
  evidence the coverage bar names, worded to resolve for every roster member (the five
  first-party `agents/` reviewers carry no `### Assessment` heading; only the vendored
  final-pass reviewer does), so the join's operand is specified rather than incidental. (#1102)
