---
bump: minor
---

### Changed

- The plugin identifier is now `prflow` (`displayName: PRFlow`). The former
  `devflow` identifier is declared as a permanent alias in
  `lib/plugin-identity.json` and as a `renames` entry in the marketplace
  manifest, so existing installations migrate automatically on the next
  marketplace update. The marketplace name itself (`devflow-marketplace`) is
  deliberately unchanged: the `renames` map is per-marketplace, so renaming the
  marketplace would put the migration map somewhere existing installs do not
  look.
- Comment triggers accept both the `/prflow:` and the transitional `/devflow:`
  command namespaces. The detected command token is always emitted in the
  canonical `/prflow:` form, because every downstream consumer compares or
  dispatches that string.
