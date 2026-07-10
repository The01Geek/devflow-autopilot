---
bump: patch
type: Fixed
---

- **Removed the stale `claude-plugins-official` cross-marketplace dependency from the installer's consumer `marketplace.json` template.** `install.sh` now emits `"allowCrossMarketplaceDependenciesOn": []`, mirroring the repo-root manifest's #142 zero-companion-dependency shape, so fresh consumers get a manifest consistent with DevFlow's documented "no companion plugins" install story. A removal-proof `lib/test/run.sh` pin now guards the empty allowlist. (#385)
