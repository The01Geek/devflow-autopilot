---
bump: patch
type: Fixed
---

- **Phase 4.3's checkpoint-4 evidence record is now machine-detectable.** The pre-ready
  base-update checkpoint records its clean-token evidence through the keyed-checkpoint carrier
  `workpad.py update --checkpoint base-update-checkpoint-4` instead of a free-text `--note`, and
  `lib/fetch-pr-context.sh` derives a `base_update_checkpoint4_present` field from its hidden
  marker — so an absent record on a run that reached Phase 4.3 is detectable without a substring
  search over prose. The key stays outside the `gha:` prefix, preserving the review-tier
  cloud/local discriminator, and the phase prose keeps a degrade-to-`--note` fallback so a
  non-canonical workpad body cannot wedge the run at its last step. This covers runs that reach
  Phase 4.3 and call `workpad.py`; a run whose agent dies before any Phase 4.3 write is out of
  scope (tracked under #1027). (#1050)
