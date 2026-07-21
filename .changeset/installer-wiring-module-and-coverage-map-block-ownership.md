---
bump: patch
---

### Added

- A focused `installer-wiring` test module (`lib/test/modules/installer-wiring.sh`,
  registered in `scripts/workflow-flight-recorder-registry.json`) carrying the
  installer and workflow-wiring coverage previously locked inside the `lib/test/run.sh`
  monolith, so `lib/test/run-module.sh installer-wiring` gives that area a focused
  verify loop instead of a full-suite run. The complete suite runs the identical module
  through the shared `devflow_run_full_suite_module` boundary.
- `lib/test/coverage_map_guard.py` now derives issue labels mechanically from
  `lib/test/run.sh` and from every `lib/test/modules/*.sh` through one shared
  implementation, and fails the suite RED when `lib/test/modules/coverage-map.json`'s
  `run_sh_blocks` half disagrees: a `run.sh` label with no entry, or a fully-extracted
  label whose entry is absent or still names `unmodularized`. A partially-extracted
  label correctly keeps `unmodularized`.
- A hand-invoked `python3 lib/test/coverage_map_guard.py . --fix` mode that repairs the
  coverage map to satisfy the new arm. It stays out of the batched generated-artifact
  pass, where the map remains a `by-hand` judgment row the pass leaves byte-unchanged.

### Changed

- `mint_blk`, `probe_tmp` and `probe_assert` moved from `lib/test/run.sh` into
  `lib/test/module-harness.sh`; the monolith now obtains them by sourcing the harness,
  so no second definition of any of them exists in the tree.
- `lib/test/module-harness.sh` now clears an inherited `DEVFLOW_GH` before a module body
  is sourced, so a focused run started with `DEVFLOW_GH` exported gets the same fixture
  isolation the complete suite's preamble already guaranteed.
- The `owner` field of the coverage map's `run_sh_blocks` half now carries real signal:
  fully-extracted labels name the module that carries them.
