---
bump: patch
---

### Added

- CI now installs a pinned Claude Code CLI, arming the `#671` `claude plugin validate --strict`
  gate that previously self-skipped on every run. The gate validates the plugin manifest and
  descends into the shipped `skills/` and `agents/` trees, so a frontmatter block that is
  malformed, absent, empty, or merely missing a required key now fails CI in any of them
  instead of passing unnoticed.
- `scripts/assert-cli-version.sh` and `scripts/retry-with-backoff.sh`: small helpers extracted
  from the workflow so their branches are covered by the test suite rather than being inline
  workflow shell that nothing drives. When every retry is exhausted, `retry-with-backoff.sh`
  names the last observed exit code in its `::error::`, so a deterministic failure (a version
  pin that 404s) is distinguishable from a transient one without re-running the job.
