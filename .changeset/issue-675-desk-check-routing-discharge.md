---
bump: patch
type: Fixed
---

- **Give a consumer fix loop an actionable discharge in the desk-check routing row.** The fix-loop context mapping table in `skills/review-and-fix/references/fixing.md` (shipped into consumer repos) told a fix loop matching the `lib/test/run.sh` desk-check row that "no equivalent backstop exists" and forbade the only generic fallback — a dead branch with no valid outcome. The row now names a discharge a consumer can perform (run the project-specific check that carries the obligation, or the consumer's own equivalent) while preserving the surviving force that a broader suite is never a substitute. The coupled `#478` routing-lint constant and destination RED-arm mutation, the review-and-fix word-budget doc cells, and the cloud-writer and prompt-mass baselines are reconciled in the same change. (#679)
