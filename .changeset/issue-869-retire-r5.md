---
bump: patch
type: Removed
---

- **Retired desk-lint rule `R5`** (the review-tier `if`/`elif` command-substitution
  *condition* guard, issue #857) from `lib/test/extract-command-shapes.py`. The
  matcher-probe review row **Shape 18** (`if VAR=$(granted-helper …)`) recorded
  **PERMITTED** (run 30310938175, 2026-07-27), so the shape the discipline-only rule
  guarded against is cloud-permitted and the stop-gap is no longer needed. The finder,
  its `REVIEW_RULES` membership, its planted control, and its `run.sh` assertions were
  removed together, and the retirement trigger prose was corrected across
  `docs/cloud-allowlist.md`, `docs/DEVFLOW_SYSTEM_OVERVIEW.md`, and the probe row. The
  retirement does not re-permit the shape in `skills/review/**` — the review-seed is
  already helper-extracted. (#869)
