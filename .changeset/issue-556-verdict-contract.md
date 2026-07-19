---
bump: minor
type: Changed
---

- **Reconciled the checklist-verifier verdict contract with a structured, executable wording-only normalizer.** The verifier now grades strictly and reports structured operands (`property_proven`, `inaccuracy_scope`) instead of self-normalizing, and a new stdlib-only helper `scripts/normalize-verdicts.py` owns the parse contract and the five-conjunct FAIL→PASS predicate. Checklist items carry `claim_provenance` (`generated_paraphrase`/`source_authored`) and, on source-authored items, `source_excerpt`, so a generator-wording artifact whose underlying property is proven no longer hard-rejects a `/devflow:review` or `/devflow:review-and-fix` run, while a false source-authored assertion still FAILs. The raw verdict, the normalization marker, and the evidence prefix survive for audit, and the helper's degraded paths fail closed with a named remedy. (#556)
