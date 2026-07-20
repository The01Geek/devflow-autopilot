---
bump: patch
---

### Added

- A batched generated-artifact pass, `lib/test/regenerate-artifacts.py`, that regenerates the
  cloud-writer runtime manifest and runs the non-writing check for each judgment-gated artifact
  (the capability-profile literals, the prompt-mass baseline, the review-bundle budget record,
  and the coverage-map ratchet) in one invocation, reporting every resulting judgment item
  together. Fix and implement loops run it once after applying edits and before each full-suite
  re-verify run, collapsing N discover-fix-rerun suite cycles into one batched pass plus one
  re-verify run.
