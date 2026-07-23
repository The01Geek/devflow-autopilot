---
bump: patch
---

### Fixed

- `lib/test/run.sh` is now analysed by ShellCheck in CI (PR #750, issue #745). The suite driver — the
  largest and most-edited shell file in the repo — had never been linted, because the obvious job
  deterministically evicts the runner: ShellCheck's dataflow pass allocates ~15 GB on a file this
  size. The lint job now installs a pinned ShellCheck ≥ 0.10.0 and runs it with
  `--extended-analysis=false` (1.15 GB, ~10 s). Both halves are required: `ubuntu-latest` ships
  0.9.0, where the flag errors and the equivalent directive is silently ignored.
- Fixed a live defect class the missing lint had let accumulate: 17 lines used markdown backticks
  inside double-quoted assert labels, which bash executed as command substitution — silently
  mangling test names and running stray commands. All 60 findings in the file are now resolved.

### Added

- `lib/test/lint-carveout-guard.py`, driven from the suite, fails RED when a tracked
  `lib/test/**/*.sh` file is neither CI-linted nor under `lib/test/fixtures/`. It immediately caught
  two more scripts (`cloud-form-layout-test.sh`, `path-portability-test.sh`) that CI had never
  linted; both are now covered, and the carve-out holds with no exemption beyond the fixtures dir.
