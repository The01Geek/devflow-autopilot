---
bump: patch
type: Fixed
---

- **Reverted the issue-1049 vendored-marketplace resolution: it broke every cloud implement run.** The `claude` job's `vendor_marketplace` step rewrote the `plugin_marketplaces` action input to the bare relative path `.prflow/vendor`, which `claude-code-action` rejects with `Invalid marketplace URL format: .prflow/vendor`, killing the `Run Claude Code` step in ~30-40 seconds on every run. The implement tier resolves the `prflow` plugin root from the repo-root `./` marketplace again, exactly as before, and `scripts/compose-vendor-marketplace.sh` is removed. Issue #1049 remains open and valid: the vendored-subtree resolution needs redoing in a form the action's marketplace input accepts. (#1049)
