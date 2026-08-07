---
bump: patch
---

`/prflow:implement` Phase 4.0.5's follow-up-issue filing procedure now lives in a
predicate-gated reference (`skills/implement/references/deferred-review-findings.md`) instead
of inline in the phase file, which every Phase 4 entry reads in full twice. A run that
deferred nothing — most runs — pays a short stub instead of the procedure.

`scripts/discover-deferral-manifests.py` gains the presence mode that gates it:
`--presence-for-pr N` reports present / absent / unestablished as exit `0` / `1` / `2`,
answering over both the run-scoped manifests and the slug-level aggregate, and deriving its
branch-slug search directory in Python so a host without `tr` resolves the same directories.
Its existing discovery-mode contract is unchanged: an invocation passing only root paths
classifies exactly the roots it classified before and returns the same exit code.

A run that does have deferrals files exactly what it filed before.
