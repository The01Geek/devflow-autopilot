---
bump: patch
type: Added
---

- **Populate the focused-test-module registry with a coverage map, ratchet, authoring convention, and a `capability-profiles` seed module.** `lib/test/modules/coverage-map.json` records the owning module for every git-tracked depth-1 `lib/`/`scripts/` code unit and each `lib/test/run.sh` assertion-name block; a new coverage guard (`lib/test/coverage_map_guard.py`, driven by the complete suite through `git` and `python3` only) turns the suite RED when a new code unit ships without a coverage decision, or when the map/registry is stale, misfiled, or wrong-shape. The `capability-profiles` module extracts the issue #561 capability-profile-generator coverage out of `run.sh`, and the cloud implement/command tiers gain the `Bash(lib/test/run-module.sh:*)` focused-runner grant. `CONTRIBUTING.md` documents the module-authoring checklist. (#591)
