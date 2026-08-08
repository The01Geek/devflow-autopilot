---
bump: patch
type: Fixed
---

- **Narrowed the stale-prose lint's gating R3 count rule so a singular ordinal reference is not read as a count claim.** `scripts/stale-prose-lint.py`'s gating `_COUNT_RE` now requires the trigger noun in plural form and refuses a numeral directly preceded by `#`, `§`, a digit, `.`, or `-` — the two guards the non-gating recognition tier already carried. A singular ordinal reference (`Step 3 item 6`) or a `#402`-style reference no longer produces a gating `STALE` row, so an editorial prose pass stops paying a review round to a gate failure about a sentence that claims no count; a genuine plural count claim still gates, and a plural ordinal (`Step 3 items 1-4`) is a disclosed residual that still gates. Consumer repositories inherit the narrowing through the vendored helper. (#1412)
