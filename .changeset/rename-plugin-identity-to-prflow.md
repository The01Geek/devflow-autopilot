---
bump: minor
---

### Changed

- The plugin identifier is now `prflow` (`displayName: PRFlow`). The former
  `devflow` identifier is declared as a permanent alias in
  `lib/plugin-identity.json` and as a `renames` entry in the marketplace
  manifest. The marketplace name itself (`devflow-marketplace`) is deliberately
  unchanged: the `renames` map is per-marketplace, so renaming the marketplace
  would put the migration map somewhere existing installs do not look.
- Comment triggers accept both the `/prflow:` and the transitional `/devflow:`
  command namespaces. The detected command token is always emitted in the
  canonical `/prflow:` form, because the consumers that *compare* it need one
  spelling. A consumer that *parses* the token must accept every declared
  namespace instead — `scripts/prepare-harness-floor.sh` now derives that set
  rather than stripping a hardcoded prefix, and announces a token it cannot
  classify instead of silently recording an empty command class.

### Upgrading

`renames` is a real, documented platform mechanism, but it is **not universal**,
and the fallback is a one-time manual reinstall:

- It **requires Claude Code v2.1.193 or later** (the marketplace-manifest schema
  documents the floor). Earlier versions ignore `renames` entirely and report
  `plugin-not-found` for the old name.
- DevFlow installs from a **remote source**, and the documented behaviour there
  is `plugin-cache-miss` after the rename, so even a supported version needs one
  `/plugin install` to fetch the plugin under its new name.
- Third-party marketplaces have **auto-update disabled by default**, so the
  `renames` map may not be fetched at all until `/plugin marketplace update` is
  run. (Installs provisioned by `init` set `autoUpdate: true` and are unaffected.)
- Managed/policy settings scopes are read-only and never auto-rewrite.

**Fallback, sufficient in every case above:** run `/plugin marketplace update`
followed by `/plugin install prflow@devflow-marketplace`. Local `/devflow:*`
slash commands do not survive the rename in any case — a skill's namespace is the
plugin name — so update local muscle memory to `/prflow:*`. The cloud
comment-trigger path and the `agent_overrides` config keys **do** keep accepting
the old namespace during the alias window.
