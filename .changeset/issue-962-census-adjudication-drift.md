---
bump: patch
type: Fixed
---

- **The frozen pin-corpus census can no longer silently disagree with its own adjudication
  table.** `lib/test/pin-corpus-classifier.py` resolves `lib/test/pin-corpus-adjudications.tsv`
  **at the census's recorded revision**, so the existing frozen-revision regeneration
  re-derived whatever rationales the census already carried and could never notice a
  working-tree table that had moved on — a table-only edit shipped a superseded rationale
  behind a green suite, the `#810` gate and green CI. The frozen-revision test now repeats its
  byte-comparison with the **working tree's** adjudication table substituted, so skipping the
  two-commit census refresh is RED, with the drifting row and column named instead of a
  whole-file diff; a companion mutation control drives the same regeneration with one rationale
  changed each run, so the comparison cannot be satisfied vacuously. The two-commit
  inventory-free protocol itself is unchanged. (#967)
