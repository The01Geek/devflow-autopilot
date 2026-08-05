---
bump: patch
type: Added
---

- **Coupled-site registry printable from `lib/test/regenerate-artifacts.py --list`.** The
  `--list` command now prints a coupled-site registry — a declared, greppable table of which
  files must change together — after everything it printed before, so the existing `artifact`
  and `conflict-*` output stays byte-for-byte unchanged. Each entry names an original file, one
  or more partner files, a coupling class, and a one-line editor note; the table is
  structurally validated at import and every named path is confirmed to exist when the list is
  printed (an entry deliberately holding old paths exempts itself with a marker). First entries
  register the `matcher-probe.yml` `EXTRAS` copy, `_WSR_SWEPT_RELPATHS`, and the
  `lib/rename-map.json` reader/mirror couplings. (#1324)
