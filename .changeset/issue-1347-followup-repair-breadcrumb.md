---
bump: patch
type: Fixed
---

- **The `## Progress` repair breadcrumb no longer announces a self-heal the call then discards.**
  Follow-up to #1347's checkpoint-4 producer hardening. `--checkpoint`'s repair of an absent
  `## Progress` runs ahead of the section-shape validation by design, so a call that repaired and
  then raised structurally — a multi-line checkpoint text, a duplicate marker — wrote nothing while
  its stderr breadcrumb claimed the workpad had been rewritten. The breadcrumb now fires only once
  that validation accepts the repaired body. Also narrows the accepted-residual paragraph in the
  `review` / `review-and-fix` prompt extensions, which still said a cloud run on a workpad lacking
  `## Progress` writes no checkpoint and misclassifies as local: that population is now the
  duplicate-section and empty-body shapes alone. (#1347)
