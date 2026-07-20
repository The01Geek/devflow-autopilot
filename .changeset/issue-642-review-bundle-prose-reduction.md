---
bump: patch
type: Changed
---

- **Shed ~2,323 words of review-engine prose to lower the review-bundle ceiling.** Condensed
  non-pinned rationale across the shared review engine (`skills/review/SKILL.md` and
  `skills/review/phases/*.md`), preserving every engine-content pin and every operative decision,
  so the shipped-default per-pass path now measures 30,016 words. Completed #618's Arm B: the
  `#618 AC3` ceiling drops from ≤ 32,399 to ≤ 30,076 words (measured + 60-word margin), retiring
  its interim status and bringing the merge-gating review bundle under the disciplined
  ≤ 30,100-word target — lowering per-pass prompt cost for every PR the judge reviews. (#642)
