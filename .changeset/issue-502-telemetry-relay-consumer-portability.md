---
bump: patch
type: Fixed
---

- **Telemetry relay consumer-portability: cloud workflows now invoke the relay helpers at the vendored path, and `install.sh` ships `telemetry-push.yml` to consumers.** `devflow-runner.yml`'s collect step and `telemetry-push.yml`'s push step now resolve their helpers at `.devflow/vendor/devflow/scripts/…` (with a repo-root fallback for self-repo checkouts) instead of the bare `scripts/` path, which was absent in consumer repos and fired a spurious "deployment fault" `::warning::` on every consumer auto-review; `telemetry-push.yml` adds a `vendor-plugin` step so the trusted pusher helper materializes in consumers, and `install.sh`'s workflow copy loop now includes `telemetry-push` so consumers receive the trusted relay, not only the producer steps. (#511)
