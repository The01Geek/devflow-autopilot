---
bump: patch
type: Fixed
---

- **The `#1219` checkout-depth pins are anchored on the value, closing a spelling that
  satisfied both of them at once.** As merged, the positive pin matched `fetch-depth: 0` as a
  *prefix* and the negative pin looked for a `1-9` digit immediately after the space — so
  `fetch-depth: 050` answered `yes` to the positive pin and `no` to the negative one, leaving
  both green with a bounded depth in force. The positive pin now requires the value to *be*
  `0`, and the negative pin tolerates leading zeros before the first nonzero digit. The
  mutation control gained planted copies for every spelling the patterns claim to handle —
  bare, single-quoted, double-quoted, and leading-zero — because a claimed spelling with no
  planted copy is an unproven claim, which is exactly how this hole survived its own review.
  (#1219)
