---
bump: patch
type: Changed
---

- **Hardened the merge-time changeset consolidator (`scripts/consolidate-changesets.py`)
  against off-happy-path inputs.** Every filesystem/permission fault (glob, changeset read,
  manifest read/write, changelog read/write, changeset delete) now raises a fail-closed
  `ChangesetError` naming the offending path, and a top-level `except OSError` backstop in
  `main` catches any unwrapped or future-added OS site — so the tool always exits `2` with a
  diagnostic instead of a bare `OSError` traceback. `consolidate` now reads and assembles both
  output files' new contents in memory before writing either, so an output-side read/parse
  fault leaves `plugin.json` and `CHANGELOG.md` byte-for-byte unchanged. `_BUMP_RANK` is now
  derived from `VALID_BUMPS` (single source, no drift), and the two changeset parse helpers
  return `NamedTuple`s addressed by field name. No happy-path behavior changes. (#306)
