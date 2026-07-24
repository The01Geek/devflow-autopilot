---
bump: patch
---

Generalize the test-module pin RESOLVED-COUNT floor and add a reverse orphan-module check (#757).

### Changed

- The pin RESOLVED-COUNT floor in `lib/test/run.sh` is now glob-derived over every
  module on disk and self-extending: it computes each module's own
  `devflow_module_pin_*` call-site count, subtracts the pins a module explicitly
  declares genuinely unresolvable with a trailing `# runtime-pin-ok:` marker, and
  asserts equality against the wrapped meta-guard's emitted RESOLVED-COUNT. The former
  hand-listed create-issue `>=150` floor and the `#591`/`#746` tranche loop over a
  hardcoded module list are gone, so no hand-maintained list or count can rot and a new
  pin-carrying module is covered the moment it lands.

### Added

- A single reverse orphan-module check in `lib/test/test_module_runner.py`
  (`test_every_on_disk_module_is_fully_wired`) enumerates every `lib/test/modules/*.sh`
  on disk and demands each is wired across all four couplings — registered, called from
  run.sh's full-suite boundary at a floor matching the registry, listed in `ci.yml`'s
  shellcheck set, and paired with an `*.inventory.md` — failing closed when any one is
  removed. The per-module forward reconciliation tests it subsumes were removed in the
  same change.
