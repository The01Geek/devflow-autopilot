---
bump: patch
---

### Added

- The suite-owned artifact registry (`lib/test/regenerate-artifacts.py`) is now the merge-conflict
  oracle. Every row carries a `conflict_class` drawn from a module-level closed set
  (`regenerate` / `reconcile-source` / `by-hand`) plus the artifact `conflict_paths` a conflict can
  land in, and `--list` emits new `conflict-class`, `conflict-path`, `conflict-recipe`, and
  `conflict-sibling` line kinds. The existing `artifact` and `budget-watch` line formats are
  byte-unchanged. The recipe is the row's existing `policy` field reused as a single source, so the
  batched pass's `governing policy:` output and the conflict rule cannot drift apart.
- A generalized regenerate-on-conflict rule in its own top-level section of the `implement`,
  `review-and-fix`, and `receiving-code-review` prompt extensions. It keys on `--list` at runtime —
  hardcoding no artifact path and no command — and fails closed both when the conflicted path is not
  a known generated artifact and when `--list` cannot run at all.

### Changed

- The three in-run merge-conflict arms (implement's Checkpoint 1 `CONFLICT` outcome, review-and-fix's
  `CONFLICT` arm, and receiving-code-review's branch-update clause) each carry a generic,
  repo-agnostic pointer directing a conflicted generated artifact to regeneration or source
  reconciliation rather than a hand-merge of its bytes.
- The narrow prompt-mass-baseline conflict sentence in the implement extension is replaced by a
  pointer to the generalized rule, so the decision is stated once.
