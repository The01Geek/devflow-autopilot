---
bump: patch
type: Changed
---

- **Renamed the `workflows.devflow` / `workflows.devflow-review` config sub-keys to `workflows.prflow` / `workflows.prflow-review`** (Tier 4 of the consumer-facing `devflow` → `prflow` rename). These were the last two `devflow`-spelled config keys a consumer sees. They migrate automatically behind the existing fail-closed scaffold **freshness gate**: a consumer whose shipped workflow files still read the superseded spelling is never silently disabled — the migration refuses, leaves the config byte-identical, and names `install.sh --apply` as the remedy, so the config key and the workflow read always move together. A deliberate `false` toggle is carried across verbatim, never coerced to a default. (#1041)
