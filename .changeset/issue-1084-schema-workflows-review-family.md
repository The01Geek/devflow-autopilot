---
bump: patch
type: Fixed
---

- **The config schema's `workflows["devflow-review"]` exposure notices now name the migrated
  key.** Ten `.prflow/config.schema.json` descriptions told a consumer their fork-PR review
  exposure persists `while workflows["devflow-review"] is true` — naming only the superseded
  spelling, which Tier 4 (#1041) renamed to `prflow-review` (`lib/rename-map.json`'s
  `frozen.config_keys` is now empty). The schema is the surface a consumer's editor validates
  against, so each notice now names both spellings, following the pattern `install.sh` already
  uses: `workflows["prflow-review"]` (or `workflows["devflow-review"]` on an unmigrated config).
  The `devflow-review.yml` / `devflow-runner.yml` / `telemetry-push.yml` workflow filenames stay
  frozen. (#1084)
