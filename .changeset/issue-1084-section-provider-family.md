---
bump: patch
type: Fixed
---

- **The light `/prflow:*` command path now honors a configured model provider.** The
  single-sourced provider resolver in `devflow.yml` selects `$cfg[$section].provider`, but both
  provider-resolver call sites set `SECTION: devflow` — the superseded config family — while
  the schema declares `prflow.provider` and `/prflow:init` scaffolds only `prflow`. A consumer
  who configured a third-party provider using the only spelling their schema validates had it
  silently ignored on the entire `/prflow:*` command path and the run fell back to the
  Anthropic-OAuth default with no diagnostic. Both sites now set `SECTION: prflow`, matching the
  family the schema declares and the scaffolder writes; `lib/test/run.sh` asserts each cloud
  workflow's `SECTION:` value matches its own config family. (#1084)
