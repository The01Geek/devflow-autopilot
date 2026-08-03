---
bump: patch
type: Fixed
---

- **The dead-run review-progress backstop no longer reports "the run wrote no verdict" on a
  review that posted one.** The `Flip review-progress comment on dead run` step in
  `devflow.yml` was `if: ${{ always() }}` and, since the #1154 upsert, would flip — or
  *create* — a terminal `❌ Review failed` review-progress comment on a clean-exit run without
  ever asking whether a verdict existed (measured: 16 false banners vs 15 real verdicts in one
  day, 0 observed precision). The step now gates on a new `scripts/dead-run-verdict-present.sh`,
  which reuses the HEAD-scoped, fail-closed `derive-review-verdict.sh` and so consults both
  channels `post-review-verdict.sh` writes (the formal review and this run's run-keyed progress
  comment); only a positively-determined verdict suppresses the banner, and every other outcome
  (no verdict, an engine error, an unresolvable HEAD, a query failure, a partial-copy
  deployment) still writes it, so a genuinely verdict-less run keeps getting the banner. (#1172)
