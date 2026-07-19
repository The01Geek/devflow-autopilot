---
bump: patch
type: Added
---

- **Configurable cloud-tier runner via the `DEVFLOW_RUNNER` variable.** Every job in the
  consumer-shipped workflows (`devflow.yml`, `devflow-implement.yml`, `devflow-review.yml`,
  `devflow-runner.yml`, `telemetry-push.yml`) now resolves its `runs-on` from a GitHub
  repository/organization variable `DEVFLOW_RUNNER`: unset or empty keeps `ubuntu-latest`
  (byte-for-byte the previous behavior for existing Linux adopters), a bare value selects a
  single-label runner (e.g. `windows-latest`), and a JSON array selects a multi-label
  self-hosted runner (e.g. `["self-hosted","windows","DevFlow"]`). Each of the five workflows
  also declares a top-level `defaults: run: shell: bash` so `run:` steps execute under bash on
  a non-Linux runner. Self-hosted / Windows runners are dispatch-enabled but not certified —
  run the documented smoke test on the target runner before treating it as production-ready.
  (#585)
