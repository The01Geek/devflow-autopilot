---
bump: patch
---

### Changed

- Plugin/marketplace identifier discriminators now derive their accepted-identifier
  set from a single source instead of hardcoding it. `lib/plugin-identity.json`
  declares the additional accepted plugin and marketplace identifiers (both empty
  today) alongside the canonical plugin name in `.claude-plugin/plugin.json`;
  `lib/plugin_identity.py` is the one reader. The vendor trust ladder
  (`vendor-slice.sh`'s `self` branch, `devflow-runner.yml`'s five FETCH_HEAD-gated
  trusted-source arms), `install.sh`'s legacy prune,
  `scripts/resolve-extra-plugins.sh`'s baked-baseline skip sets,
  `scripts/resolve-review-overrides.py`'s closed `agent_overrides` allowlist and
  `scripts/provision-local-settings.sh`'s marketplace registration all resolve their
  accepted set from that source rather than a literal. Behaviour is unchanged while
  no additional identifier is declared.

### Added

- `lib/generate-plugin-identity.py` compiles the accepted-name discriminator into the
  three surfaces that structurally cannot read it at runtime, each banner-stamped with
  a sha256; `--check` (wired into the suite) turns any drift RED with a directional
  diff. Those regions are never hand-edited.
- `scripts/provision-local-settings.sh` now migrates: it removes a superseded
  DevFlow marketplace/plugin registration while writing the canonical one, so a repo
  provisioned under a previously-declared identifier is not left with two live
  registrations. No-op while no additional identifier is declared.

### Fixed

- `scripts/provision-local-settings.sh`'s post-write "which keys changed" probe always
  errored (`getpath` read its path argument from the settings object instead of the
  probe row), so every provisioning run silently degraded to the generic breadcrumb.
  The breadcrumb now names the keys it actually wrote or removed.
