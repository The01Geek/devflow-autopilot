---
bump: patch
type: Fixed
---

- **Grant instructions now name the live `prflow.allowed_tools` config key.** The Tier 1
  rename moved the top-level config object `devflow` to `prflow`, and config keys carry no
  transitional read-through by design, but a number of docs, shipped skill prompt surfaces,
  code comments and the config schema's own description text still told readers to write a
  tool grant under the dead `devflow.allowed_tools` spelling. A consumer whose config already
  carried a `prflow` family and followed one of those instructions got a grant that was
  silently ignored — the workflow reads `.prflow.allowed_tools // []`, so the extraction
  yielded an empty `allowed_tools_extra` while the top-level-key-presence guard still passed,
  leaving their build or test tool ungranted on the cloud tier with no error and no
  breadcrumb. Every such instruction now names the live key, including the remedy string an
  implement run writes into a durable workpad record on its `Blocked` path. Occurrences that
  are correct as written — the changelog, the frozen pin-retirement census records, and the
  rename-substitution test fixture — keep the old spelling, as do the frozen workflow
  filenames, `DEVFLOW_*` environment variables and `/devflow:*` command aliases. No
  executable read of the key existed anywhere in the tree, so this carries no runtime
  behavior change. (#1070)
