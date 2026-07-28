---
bump: patch
---

### Added

- CI now installs a pinned Claude Code CLI, arming the `#671` `claude plugin validate --strict`
  gate that previously self-skipped on every run. The gate validates the plugin manifest and
  descends into the shipped `skills/` and `agents/` trees, so a malformed, absent, or empty
  frontmatter block in any of them now fails CI instead of passing unnoticed.
- `scripts/assert-cli-version.sh` and `scripts/retry-with-backoff.sh`: small helpers extracted
  from the workflow so their branches are covered by the test suite rather than being inline
  workflow shell that nothing drives.
