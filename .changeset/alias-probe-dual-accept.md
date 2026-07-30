---
bump: patch
type: Changed
---

- **Declare one THROWAWAY plugin alias, `devflow-alias-probe`, to exercise the name-agnostic
  identity mechanism end to end for the first time.** `lib/plugin-identity.json`'s
  `plugin_aliases` has been `[]` since the mechanism landed, so every discriminator built to
  accept a second accepted name has only ever resolved the canonical one. This declares a
  single disposable alias and regenerates the four baked regions
  (`.github/actions/vendor-plugin/vendor-slice.sh`, `install.sh`,
  `.github/workflows/devflow-runner.yml`'s workflow-level `env:`, and
  `scripts/resolve-extra-plugins.sh`) with `lib/generate-plugin-identity.py`, so the widened
  accepted set is observable in a real cloud run before a rename bets on it.
  `marketplace_aliases` is deliberately untouched.

  **`devflow-alias-probe` is not a real identifier and is not a candidate name.** It names
  no plugin, no marketplace and no repository, it is never published, and it is
  TEMPORARY — a follow-up removes it once the post-merge observation is recorded. Do not
  build anything on it. (#943)
