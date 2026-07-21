---
bump: patch
type: Added
---

- **Relocation-drift discovery in the implement-time changed-contract sweep.** Phase 2.3.0
  now arms on relocation of a prose literal, heading, section, or file path — not only a code
  symbol — mandating a whitespace-normalized + rendered-surface enumeration of the moved
  content's old-location citations (recovered from the working-tree diff's deletion hunks or a
  `git diff --name-status` rename/deletion entry) so a single-branch relocation stops leaving
  an orphaned pin. `lib/test/pin-corpus-lint.py` gains an opt-in `--reloc` relocation-diagnosis
  net on the `wrapped` guard's `ABSENT` branch that turns a bare `ABSENT` into `relocated to
  <file>` (or a genuine deletion), fail-closed on an unresolvable/empty search set. (#661)
