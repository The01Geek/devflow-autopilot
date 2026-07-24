---
bump: patch
---

Retire the word-budget / prompt-length enforcement subsystem. The word ceilings
(review-bundle, review-and-fix, create-issue, and the CLAUDE.md length ratchet), the
prompt-mass byte census, the figure-partition guard, the budget-delta reporter, and the
three budget docs are removed, along with their coupled test pins, reconcile machinery,
regenerated-artifact rows, and the review engine's Phase 4.1.8 prose-cutover gate. The
review engine runs with one fewer gated phase. The intent — keep prompt prose lean —
survives as unenforced advisory guidance in `CLAUDE.md` and the implement / review-and-fix
prompt extensions. No runtime behavior changes: the subsystem had no runtime reader.
