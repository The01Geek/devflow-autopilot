---
bump: patch
type: Changed
---

- **Split the `/devflow:review-and-fix` engine into a thin root + durable step references.**
  `skills/review-and-fix/SKILL.md` is now a thin root (≤3,500 words) that keeps the invocation
  contract, the run-scoped `iter-<N>.json` schema, the lifecycle, a Step-routing table, a
  fail-closed reference-loading contract, and the terminal verdict→chat mapping. The step
  procedures (pre-fix gates, shadow review, fixing, fix-delta gate, convergence, Loop Exit, loop
  control, error handling) are extracted, with routing and durable-continuation adaptations, into reloadable references under
  `skills/review-and-fix/references/`, each loaded at step entry behind a single ordered
  boundary; an unreadable reference takes a mapped fail-closed outcome that never permits a clean
  approve. Durable `current_step`/`current_substep`/`pending_dispatch` operands in the run-scoped
  record let a compacted or resumed run recover its position from the record rather than recall,
  and an always-resident root rule re-reads the active reference after every subagent/skill
  return. Full lifecycle and shadow behavior are preserved; the always-loaded prompt is reduced
  by more than 33,000 words. (#539)
