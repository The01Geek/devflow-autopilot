---
bump: patch
---

### Added

- A **"do not rename" inventory** for the consumer-facing `DEVFLOW_*` variables, secrets and
  environment overrides that the DevFlow → PRFlow rename deliberately left alone (issue #1004).
  These live outside your repository — in GitHub's settings and in your shell profile — and
  nothing PRFlow ships reads a `PRFLOW_*` equivalent, so renaming one does not move a setting,
  it removes it. Most remove it *silently*: an unresolvable GitHub variable is indistinguishable
  from one you deliberately never set, so every gate takes its "not configured" arm and the run
  goes green under a degraded identity. The advisory names each identifier, where you set it,
  and exactly what renaming it does — including that renaming `DEVFLOW_RUNNER` silently relocates
  every job to a GitHub-hosted runner while that job still carries your App private key and
  provider API key in its environment. It lives in `docs/cloud-setup.md` ("Why these settings are
  still called `DEVFLOW_*`"), with a pointer from `docs/install.md`.
- `install.sh` now emits a matching advisory NOTICE when it upgrades an **existing** installation
  — the population that already has these names configured. A first-time install stays silent.

### Internal

- The frozen population is recorded machine-readably as `frozen.env_identifiers` in
  `lib/rename-map.json`, alongside the two-arm criterion that selects it and the two names
  adjudicated out of it (`DEVFLOW_PROMPT_EXTENSION_ROOT`, `DEVFLOW_CONFIG_FILE`) with the
  deciding arm for each. `lib/generate-env-freeze-advisory.py` renders the advisory region from
  that block and re-runs the criterion over the tree, so a workflow that starts reading a new
  `vars.DEVFLOW_*` name — or a recorded name whose read side goes away — fails the suite until
  it is adjudicated.
