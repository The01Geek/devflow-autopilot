---
bump: patch
type: Security
---

- **Close the cloud-writer tamper-detection gap on `render-prompt-extension.sh`.** The
  prompt-extension render wrapper — whose stdout becomes the merge-gating reviewer's own
  prompt — is now a registered required helper head on all three cloud profiles and its
  bytes are hashed in the SHA-pinned runtime trust manifest, so mutating it turns contract
  verification red. `LEGACY_PROFILE_BASELINE` advances from `2.30.100` to `2.31.16` (the
  release that first shipped the wrapper), and the frozen legacy-grant snapshot
  re-snapshots with it per the established cadence rule. Consumers installed below the new
  baseline are told, through the existing operator-facing refresh action, to refresh
  workflows and vendored plugin content together before their next cloud-writer run. (#1363)
