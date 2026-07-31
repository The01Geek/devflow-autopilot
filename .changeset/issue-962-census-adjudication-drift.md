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
  byte-comparison with the **working tree's** adjudications reconciled into the recorded
  revision's table, so changing an adjudicated cell for a key the census already carries is RED,
  with the drifting row and column named instead of a whole-file diff; a companion mutation
  control drives the same reconcile-then-regenerate path with one working-tree rationale changed
  each run, so the comparison cannot be satisfied vacuously. Only keys the two files share are
  compared: an adjudication key is a hash of its site's literal, so rewording a pinned literal
  re-keys the same adjudication, and the census — a frozen snapshot whose lag is fail-closed by
  design — is not thereby stale. The two-commit inventory-free protocol itself is unchanged.
  (#967)
