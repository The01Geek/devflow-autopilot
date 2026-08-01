---
bump: patch
type: Fixed
---

- **Grant instructions now name the live `prflow.allowed_tools` config key.** The Tier 1
  rename moved the top-level config object `devflow` to `prflow`, and config keys carry no
  transitional read-through, but docs, shipped skill prompt surfaces, code comments and the
  config schema still told readers to write a tool grant under the dead
  `devflow.allowed_tools` spelling. A consumer whose config already carried a `prflow`
  family and followed one of those instructions got a grant that was silently ignored — no
  error, no breadcrumb, their build or test tool simply ungranted on the cloud tier. Every
  `allowed_tools` grant instruction now names the live key, including the remedy an
  implement run writes into its workpad on the `Blocked` path and the light command path's
  row in the system overview's configuration reference. Historical records and test fixtures
  keep the old spelling, as do the identifiers frozen in `lib/rename-map.json`; instructions
  naming other superseded `devflow.<key>` leaves are tracked separately. Nothing executable
  ever read the dead spelling, so there is no runtime behavior change. (#1070)
