---
bump: patch
---

### Fixed

- `devflow-implement.yml` now re-anchors the hosted-runner workspace prefix in
  `devflow_implement.allowed_tools` onto the live `$GITHUB_WORKSPACE` before splicing it
  into `--allowed-tools`. That prefix embeds the repository name twice, so renaming the
  repository would have left 25 helper grants matching nothing — and an ungranted head is
  silently denied, so the loss would have surfaced as a cloud implement run that quietly
  did less rather than as an error. The transform is a no-op until a rename, leaves
  out-of-workspace absolute grants untouched, and falls back to the authored tokens when
  the workspace is unset. Completes the half of issue #928 that `matcher-probe.yml`
  deferred.
