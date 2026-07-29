---
bump: patch
---

### Fixed

- Corrected stale comments in `.github/workflows/devflow.yml` that still described the
  automatic pull-request-triggered review tier — withheld by issue #936, with
  `devflow-review.yml` removed from the tree — as a live `synchronize`-driven mechanism.
  The file header, the `review_dedupe` policy block, and the Signal 2 comment now state
  that the tier is withheld here and that the dedupe gate is retained for consumers whose
  installed copy predates the withholding. Comment-only: no executable line changed.
