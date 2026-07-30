---
bump: patch
---

### Changed

- **Retire the throwaway `devflow-alias-probe` plugin alias.** `lib/plugin-identity.json`'s
  `plugin_aliases` returns to `[]` and every dependent region is regenerated, so the four
  baked copies (`.github/actions/vendor-plugin/vendor-slice.sh`,
  `.github/workflows/devflow-runner.yml`, `install.sh`, `scripts/resolve-extra-plugins.sh`)
  accept the canonical `devflow` only. The probe had already established what it was declared
  for — that a second accepted identifier propagates to every baked region, that the
  agent-namespace roster guards must be alias-agnostic, and that the canonical discriminator
  still resolves with an alias declared — and its removal was a stated condition of the change
  that introduced it: leaving it in ships a trust-discriminator widening for an identifier
  nobody owns. The name-agnostic mechanism itself is untouched, as is the alias-agnostic
  hardening of the roster guards.
- Two comments that were corrected *because* an alias was declared —
  `lib/generate-plugin-identity.py`'s `payload_install` docstring and `install.sh`'s
  superseded-identifier gate comment — are reconciled with the tree they now ship in: each
  states the conditional the code implements, names the current (empty) state as a property
  of the manifest rather than of the function, and tells the reader to re-read the manifest
  before asserting which way the gate falls.
