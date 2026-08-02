---
bump: patch
---

### Fixed

- A cloud review run that ended **without a verdict** could leave its pull request reading as a clean pass. `devflow.yml`'s dead-run backstop was gated on three outcome disjuncts (a failed Claude step, a cancellation, or a final engine result carrying `is_error`), so a run that exited cleanly having produced nothing matched none of them; and the backstop was flip-only, so a run that died before the review engine seeded its progress comment had nothing to flip and left the pull request unmarked. The step now runs on every job end and **upserts**: an interim `🚀 Reviewing` comment is flipped to `❌ Review failed` as before, and a confirmed clean absence is *created* in that terminal state, carrying the run-keyed marker on line 1 so a retry resolves it and takes the already-terminal arm instead of posting a second comment. A comment already carrying a verdict is still left byte-untouched, a failed lookup never authorizes a create, and the backstop still always exits 0.

### Added

- `scripts/describe-dead-run-cause.sh` — the dead-run cause selector, extracted out of `devflow.yml`'s inline `if`/`else` chain. The Claude step's raw outcome and the engine's `is_error` partition the run-end space into four modes, and the helper owns that selection and its arm order so each arm is drivable by the test suite rather than asserted through a message grep.

### Changed

- The `/prflow:review-and-fix` bundle no longer claims, unqualified, that the fix loop is "silent on GitHub by design". The loop runs the review engine's Phases 0 through 4.3 verbatim, so its inline engine maintains the run's progress comment; what the loop posts is no formal review and no verdict comment.
