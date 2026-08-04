---
bump: patch
---

### Changed

- `/prflow:implement` Phase 4.3 no longer runs the project test suite twice over one tree. The base-branch update checkpoint 4 `UPDATED` arm previously mandated a post-merge whole-suite re-run before publishing; the Phase 4.3 completion-evidence flight (issue #1087) already runs after that checkpoint and before the publish decision, over the same merged tree — checkpoint 4's merge is one of the candidate-changing operations it exists to cover — and already routes a failed suite, a non-empty skip population, or an unrunnable verification command to `Blocked` instead of publishing. The redundant earlier run is removed, saving one whole-suite run on every run whose base branch advanced. The completion gate keeps its whole-suite requirement and its Blocked-on-non-pass behavior unchanged, and the `UP_TO_DATE` / `DISABLED` / `CONFLICT` arms are untouched.
