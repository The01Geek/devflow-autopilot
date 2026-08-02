---
bump: patch
type: Fixed
---

- **Both settings provisioners now fail closed when a directory sits at the settings path.** A
  directory (or a symlink to one) at `.claude/settings.json` was treated as absent by the
  `[ -f "$SETTINGS" ]` test, so the create path ran and the atomic `mv` dropped the temp file
  *inside* the directory while reporting success and exiting 0 — the requested settings were never
  written anywhere the runtime reads. `scripts/provision-local-settings.sh` and
  `scripts/provision-auto-mode.sh` now carry an explicit `[ -d "$SETTINGS" ]` guard above the
  `[ -f ]` test that exits non-zero with a specific breadcrumb. A dangling symlink and a FIFO are
  deliberately left alone (the `mv` correctly replaces them), asserted as negative controls so the
  fix cannot silently widen into a legitimate symlink-into-dotfiles setup. (#1082)
