---
bump: patch
type: Added
---

- **Measure the `/devflow:review-and-fix` command tier's command shapes at the desk.**
  `lib/test/extract-command-shapes.py` now accepts `--profile command`, and the suite drives it
  over the review-and-fix bundle (its root, references, and the shared review engine it executes
  inline) so a denied command *shape* on the manual `/devflow:review-and-fix` PR-comment tier turns
  RED at the desk instead of only surfacing as a silent cloud denial. The command-tier rule set
  mirrors the read-write implement tier (`command`-tier denied shapes ⊆ `implement`-tier denied
  shapes), the assumption the matcher-probe `command-probe` job confirms empirically. Removed the
  fence-less loop-control prose that provoked an improvised, ungranted `git check-ignore` in the
  motivating dead run — `.devflow/tmp/` is already covered by the standing `/.devflow/*` ignore
  rule, so no runtime ignore-coverage check is needed. (#696)
