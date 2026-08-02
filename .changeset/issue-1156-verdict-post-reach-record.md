---
bump: patch
---

### Fixed

- A standalone review run that never reaches Phase 4.4 now leaves a durable record of that
  fact. `post-review-verdict.sh` writes a run-scoped receipt of the outcome line it emitted,
  a new `check-verdict-post-reached.sh` reduces that receipt to `REACHED` / `NOT-REACHED` /
  `UNESTABLISHED`, and an `always()` step in the `command` job posts one pull-request comment
  when no receipt is found. Previously such a run exited `success` with a verdict-looking
  comment it composed itself, an untouched reviews API, and nothing that told a maintainer
  whether the verdict post had been refused or never attempted. The comment states what was
  observed and names both causes an absent receipt can have — the emitter never ran, or it
  ran and could not write its receipt — plus the check that separates them, rather than
  asserting either. `UNESTABLISHED` deliberately never collapses onto `NOT-REACHED`: a
  receipt that cannot be read warns without asserting, and posts no comment. The step is
  gated to pull requests, so a review command on a plain issue draws nothing.
