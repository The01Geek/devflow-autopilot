---
bump: patch
type: Fixed
---

- **`reception_identity`: derive a content-based identity independent of stat timing.** The
  reception-session candidate identity seeded its temporary index from the repository's index,
  which carries each entry's pre-edit stat data, so a tracked file rewritten to the same size
  within the mtime tick the index cached read as stat-clean — `git add -A` never re-hashed it and
  the derived tree carried the stale blob, silently colliding two distinct working trees on one
  identity. The seeded temp index is now backdated to make git's own racy-index rule force a
  content re-hash, which (unlike an unqualified `add --renormalize`) still honors the skip-worktree
  and `assume-unchanged` entries git deliberately does not re-stat. The backdate is read back and
  verified before anything is staged, so a filesystem that reports success while storing a
  different value refuses the derivation with a named reason instead of silently reproducing the
  stale-identity collision. (#1138)
