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
- The provenance layer fails **safe** whenever a digest cannot be established, and the blast
  radius matches the cause:
  - **No working `python3`** — stock Windows / Git-Bash before the shim provisioner has run.
    Nothing can be digested, so the upgrade preserves **every** artifact it finds, offers each
    new version as a `<path>.devflow-new` sidecar, and writes no manifest.
  - **A read error on one artifact** while `python3` works — an unreadable file, or one
    unreadable file inside a composite-action directory. Only **that** artifact is preserved
    and offered as a sidecar; every other artifact is classified and written as usual, and the
    manifest is still recorded — the preserved one simply keeps its previous entry rather than
    being re-recorded against bytes nothing could read.

  Each case reports the cause that actually applied and the remedy that matches it, rather
  than naming a missing interpreter on a host whose interpreter works.

  Whether an artifact *exists* is decided without `python3` in both cases, so a genuinely absent
  artifact is still created and a first-time install on such a host is unaffected; what an
  unreadable digest costs is the comparison, never the consumer's bytes. Both report distinctly
  from "no recorded digest" (`provenance UNESTABLISHED`), and each names its own remedy.
- The upgrade path surfaces the **withheld automatic-review tier** (issue #936) when a
  repository still carries it, naming the #930/#920 exposure, and offers removal behind the
  explicit `--remove-withheld-review-tier` opt-in. The opt-in sets `workflows["devflow-review"]`
  to `false` and then deletes the three workflow files, and states that the branch-protection
  context is a step no installer can perform. Deletion is guarded by a **per-file signature**
  each withheld workflow actually carries — not by the mere presence of the string `devflow`,
  which a consumer's own `telemetry-push.yml` may legitimately contain (a `.devflow/**` path
  filter, a comment) and which would otherwise have deleted their file. The config key is
  turned off *before* the files are removed: that is the only order whose interrupted state
  is self-healing, since once the files are gone no later run reaches the config edit.
- The dry-run diff covers `.claude/plugins/` as well, so the recursive removal of a stale
  pre-relocation `.claude/plugins/devflow` tree is shown rather than performed unpreviewed.
  The consumer's wider `.claude/` is still neither written nor diffed.
- An artifact the installer replaces is staged beside its target and swapped into place, so a
  failure mid-copy can no longer leave a half-written file or composite action behind. That
  mattered more than a partial write usually does here: the aborted run never reaches the
  manifest write, so the next upgrade would compare the half-copied bytes against the old
  digest, call them a local edit, and preserve the corruption on every subsequent run.
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
