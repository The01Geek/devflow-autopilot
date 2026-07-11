---
bump: patch
type: Changed
---

- **Run the authoring-side sweeps on each fix delta, and charter Phase 3.2 cleanup agents as quality-only.** `review-and-fix` Step 3 gains item 3b: on every iteration in which Step 3 applies fixes, the fix author now runs the implement Phase 2.3 authoring-side sweeps (§2.3.0c trigger (a) new-guard operand trace, §2.3.0c trigger (b) prose-policy operand check, §2.3.4 external-output reproduction obligation) against the fix delta, each gated by its own phase-2 trigger, with evidence directed to the loop's own `iter-<N>.json` when it runs standalone — the author-side counterpart of the blinded Step 3.5 gate, which stays byte-identical. Phase 3.2 (`/simplify` self-review) is re-charted: `/simplify` is described as quality-only per its charter, the orchestrator no longer solicits a correctness/guard-class verdict from a cleanup agent nor records its "clean" as correctness evidence, and the Phase 3.3 reviewers — whose dispatch prompts carry the repo's guard classes — are named as the owners of correctness. (#377)
