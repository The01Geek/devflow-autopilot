---
bump: patch
type: Changed
---

- **Register the deferred cloud-writer helper heads and advance the legacy profile baseline.** `apply-issue-dependencies.py` (issue #1011) and `resolve-existing-pr.sh` (issue #782) are now members of `REQUIRED_HELPER_HEADS["implement"]`, and `LEGACY_PROFILE_BASELINE` advances from `2.15.13` to `2.30.100`, so the required-subset guarantee finally covers both heads. A cadence rule now lives at the constant's definition: the baseline advances — and the frozen legacy-grant snapshot re-snapshots with it — whenever a profile's granted helper-head set in `lib/capability-profiles.json` changes. (#1034)
