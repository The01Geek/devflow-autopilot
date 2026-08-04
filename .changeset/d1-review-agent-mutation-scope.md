---
bump: patch
---

### Changed

- The five `pr-review-toolkit` review agents (`code-reviewer`, `comment-analyzer`, `pr-test-analyzer`, `silent-failure-hunter`, `type-design-analyzer`) now scope their mutation/half-revert verification to the narrowest test target covering the guard under test, instead of launching the project's whole test suite. All five are dispatched on every review roster pass and again on every shadow pass, and each could previously launch a full suite per finding from inside a subagent where the orchestrator never saw the cost. Mutation evidence needs only one assertion to go RED, so a whole-suite run proved nothing extra. The block stays read-only and advisory and keeps its `mktemp` temporary-copy discipline unchanged.
