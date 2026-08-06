---
bump: patch
type: Fixed
---

- **Hardened the Phase 4.3 checkpoint-4 evidence producer so every legitimate completing run can
  record one.** Three independent defects are fixed. `workpad.py update --checkpoint` now repairs
  an absent `## Progress` section — creating it at the head of the section list, ahead of its own
  section-shape validation — where previously both it and its documented `--note` fallback raised
  on that shape, leaving a run with no way to record at all; an empty or whitespace-only body is
  untouched and still raises, and a duplicated `## Progress` or a misplaced marker still fails
  closed with no PATCH. The Phase 4.3 tier-refused arm now records through its own keyed
  checkpoint, `base-update-checkpoint-4-tier-refused`, instead of a prose-only reflection, so a
  consumer can distinguish "the base was reconciled" from "the tier refused the check"; like the
  clean-token key it carries no `gha:` prefix, and the arm still publishes and still does not
  route to `Blocked`. And the Phase 1.3 resume arm now passes the new
  `workpad.py update --strip-inherited-checkpoints`, on both the cloud and local arms, so a
  resumed run no longer inherits the previous attempt's checkpoint-4 row and
  `base_update_checkpoint4_present` describes the last attempt rather than any attempt; the strip
  is scoped to the declared key set so `gha:`-prefixed rows are untouched, and combining it with
  `--checkpoint` for one of those same keys is rejected before any PATCH. (#1347)
