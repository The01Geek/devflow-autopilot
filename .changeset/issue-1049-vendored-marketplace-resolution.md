---
bump: patch
type: Fixed
---

- **This repository's cloud implement run now resolves the plugin root to the vendored subtree, matching every consumer.** The repo-root marketplace sources the `prflow` plugin at `./`, so this repo's cloud implement run resolved `$CLAUDE_SKILL_DIR` to `<workspace>/skills/<name>` while every consumer resolves it from `.prflow/vendor/prflow` — leaving the shipped helper-path shape with no coverage here. The `claude` job now composes a job-local marketplace rooted at `./.prflow/vendor` (via `scripts/compose-vendor-marketplace.sh`) and swaps the repo-root `./` marketplace entry for it, implement tier only. The tracked `.claude-plugin/marketplace.json` and the baked marketplace baseline literal are untouched; the manual-command and review tiers keep `./`. The composition degrades on a partial/absent vendored tree with a `::warning::` naming `prflow_version`. This supersedes the reverted first attempt, which emitted the entry as a bare relative path and was rejected by `claude-code-action`'s marketplace-input validator; the emitted entry is now normalized to the `./`-prefixed local-path form the action accepts. (#1049)
