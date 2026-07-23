---
bump: patch
---

### Fixed

- `lib/test/run.sh` is now analysed by ShellCheck in CI (PR #750, issue #745). The suite driver — the
  largest and most-edited shell file in the repo — had never been linted, because the obvious job
  deterministically evicts the runner: ShellCheck's dataflow pass allocates ~15 GB on a file this
  size. The lint job now installs a pinned ShellCheck ≥ 0.10.0 and runs it with
  `--extended-analysis=false` (1.15 GB, ~10 s). Both halves are required: `ubuntu-latest` ships
  0.9.0, where the flag errors and the equivalent directive has no effect. All 60 findings in the
  file are resolved — fixed where real, annotated with a reason where the check was a false
  positive.
- Fixed a live defect class the missing lint had let accumulate: assert labels that used markdown
  backticks inside a double-quoted string, which bash executes as command substitution — so the
  suite was running stray `--issue`, `must`, `after`, and `follow-up` commands on every run and
  rendering those assertion names with the backticked span deleted. Every such label is fixed,
  and the suite now guards the class (below).

### Added

- `lib/test/lint-carveout-guard.py`, driven from the suite, fails RED when a tracked
  `lib/test/**/*.sh` file is neither CI-linted nor under `lib/test/fixtures/`. It immediately caught
  two more scripts (`cloud-form-layout-test.sh`, `path-portability-test.sh`) that CI had never
  linted; both are now covered, and the carve-out holds with no exemption beyond the fixtures dir.
- A suite guard against the backtick-in-assert-label class above. ShellCheck cannot gate it —
  backticks are reported as `SC2006`, a *style*-severity check that `--severity=warning` filters
  out, so only a minority of the live instances were caught at all, and only incidentally (their
  contents happened to parse as a flag or a keyword). The new scan fails RED on any unescaped
  backtick in an assertion label; an escaped ``\` `` is inert and stays legal.
