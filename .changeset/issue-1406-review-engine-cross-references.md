---
bump: patch
type: Fixed
---

Repaired two false cross-references from the `/prflow:review-and-fix` fix loop into the shared
review engine. The Step 2.6 over-grade calibration gate named a section of `skills/review/SKILL.md`
that does not exist; it now names `skills/review/phases/phase-4-verdict.md`, where the over-grade
shapes are actually defined. The shadow-review novelty rule paraphrased the engine's
`defect_signature` corroboration rule while dropping its clause treating a `null` `line_range` as
overlapping any range in the same file when `kind` matches; the paraphrase is removed in favour of a
pointer to `skills/review/phases/phase-3-agents.md`, so a `line_range: null` finding the previous
iteration already recorded no longer reads as new and no longer promotes a spurious iteration that
could surface as `APPROVE WITH UNRESOLVED SHADOW FINDINGS`.
