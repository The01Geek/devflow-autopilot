---
bump: patch
type: Fixed
---

- **The `## Progress` repair breadcrumb is now emitted only for a repair that survives every
  structural check in the update.** Follow-up to #1347's checkpoint-4 producer hardening.
  `--checkpoint`'s repair of an absent `## Progress` runs ahead of the section-shape validation by
  design, so any later abort discards the repaired body with no PATCH — the section-shape guards
  themselves, and equally the `Last updated` / `Status` / `Branch` header checks, the
  `--rewrite-ac` guards, and the completion-evidence validator that run after them. The breadcrumb
  previously fired from inside the repair, claiming a rewrite those aborts had thrown away; it is
  now deferred to the mutation pass's successful return, after all of them. Also narrows the
  accepted-residual paragraph in the `review` / `review-and-fix` prompt extensions, which still
  said a cloud run on a workpad lacking `## Progress` writes no checkpoint and misclassifies as
  local: that population is now the duplicate-section and empty-body shapes alone. (#1347)
