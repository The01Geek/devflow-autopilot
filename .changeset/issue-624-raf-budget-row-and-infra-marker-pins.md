---
bump: patch
---

### Added

- `lib/test/regenerate-artifacts.py` now covers `docs/review-and-fix-budget.md` as a sixth
  registry row, so a loop that edits the review-and-fix root, its prompt extension, or any
  `skills/review-and-fix/references/*.md` learns the budget record went stale from the batched
  pass instead of a full suite run later. The row is git-staleness only — it measures nothing,
  deferring figure correctness to the suite's own word counter, exactly like its review-bundle
  sibling.

### Changed

- The budget row's record and watch list are now read from the registry row itself
  (`record` / `watch_literals` / `watch_globs`) rather than module-level constants, so the
  registry stays the single enumeration point with more than one budget row.
- `--list`'s `budget-watch` and `budget-watch-missing` lines carry the owning row name as their
  second field. A consumer keying on the bare path must now key on `(row, member)`.

### Removed

- The helper header's `KNOWN UNCOVERED SIBLING` disclosure, which became false once the sibling
  record gained a row.

### Fixed

- The `[arm8] ` (module registry unreadable) and `: unreadable:` (census JSON read failure)
  `infra_markers` literals were declared but unpinned: deleting either left the focused module
  green while the corresponding generator input failure would have been reported as a resolvable
  judgment item rather than an unchecked artifact. Both are now driven by their own module arm.
