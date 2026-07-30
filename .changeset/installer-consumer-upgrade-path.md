---
bump: minor
---

### Added

- `install.sh` now has a real **consumer upgrade path**. Re-running it in a repository that
  already carries a DevFlow installation is **dry-run by default**: it prints the plan and a
  unified diff of every byte it would change and writes nothing until you re-run with
  `--apply`. A first-time install still applies immediately, so the documented one-liner is
  unchanged; `--dry-run` forces the preview there too, and `DEVFLOW_DRY_RUN=1` /
  `DEVFLOW_APPLY=1` select the same modes for a `curl | bash` invocation that cannot pass a
  flag. The preview is not a second implementation of the plan — it runs the real install
  into a sandbox copy of the consumer's own tree and diffs it.
- Installed artifacts now carry provenance in `.devflow/install-manifest.json` (a sha256 per
  artifact). An upgrade updates an artifact whose bytes match the recorded digest, leaves an
  already-identical one alone, recreates a deleted one, and **preserves** one that was
  hand-edited — writing the new version to `<path>.devflow-new` for a human merge instead of
  overwriting. An installation with no manifest (predating it, or a skipped-version jump) is
  treated as unverified rather than pristine: unknown is never collapsed onto "unmodified".
- The upgrade path surfaces the **withheld automatic-review tier** (issue #936) when a
  repository still carries it, naming the #930/#920 exposure, and offers removal behind the
  explicit `--remove-withheld-review-tier` opt-in. The opt-in deletes the three workflow files
  (signature-guarded) and sets `workflows["devflow-review"]` to `false`, and states that the
  branch-protection context is a step no installer can perform.
- The upgrade path reports a `.claude/settings.json` still registering a **superseded**
  plugin/marketplace identifier and routes the consumer to `/devflow:init`, which already owns
  that migration through `scripts/provision-local-settings.sh`. `install.sh` still writes no
  `.claude/settings.json`.
- `DEVFLOW_SRC` skips the clone and installs from an already-materialized source tree — the
  offline seam the test suite drives real end-to-end fixture upgrades through.

### Changed

- The local `marketplace.json` `install.sh` writes is now composed from the **generated plugin
  identity region** rather than hand-spelled literals, and the region carries the canonical
  plugin/marketplace pair plus the superseded identifier sets alongside the existing
  discriminator ERE. Declaring an alias in `lib/plugin-identity.json` and regenerating is the
  only edit an identifier change needs in the installer.
