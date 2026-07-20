---
bump: patch
type: Fixed
---

- **The stale counted-prose lint is now move-aware — a byte-identical relocation no longer
  produces a gating `STALE`.** An extraction refactor relocates prose without authoring it, but
  a relocated line is an *added* line in the unified diff, so `scripts/stale-prose-lint.py`
  re-graded it as newly authored and resolved its claims against the destination file's
  context — a pure move could fail a Phase 0.6 gate on unchanged prose. A diff-added prose line
  whose full text also appears as a removed line in the same caller-supplied diff is now exempt,
  bounded by a multiplicity rule (added occurrences must not outnumber removed ones,
  diff-globally) and a referent rule (every diff-added referent line must itself be relocated,
  so PR-authored referent growth still gates). The row is demoted rather than deleted: the
  would-be `STALE` is emitted as a non-gating `UNRESOLVABLE` carrying the original diagnostic
  behind a relocation-naming prefix, keeping the co-located contradiction visible without
  enforcing. The change lands behind the helper's unchanged CLI contract, so the cloud review
  Phase 0.6, the fix-loop pre-check, and the CI self-scan all inherit it with no caller edits
  and no new tool grants. (#631)
