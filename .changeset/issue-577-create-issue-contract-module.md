---
bump: patch
type: Added
---

- **Focused `create-issue-contract` test module for fast local RED/GREEN iteration.** The
  create-issue contract coverage (Step 3.6 fresh-context audit, the state-owner cutover,
  the authoring-discipline rules, and the revision-delta verification guard) is now a
  selectable module at `lib/test/modules/create-issue-contract.sh`, runnable on its own with
  `bash lib/test/run-module.sh create-issue-contract` and executed by the complete suite
  through the existing fail-closed module boundary. `lib/test/module-harness.sh` gains a shared
  namespaced pin API (`devflow_module_pin_count` / `devflow_module_pin_unique` /
  `devflow_module_pin_present` / `devflow_module_pin_red_under`) whose fixed-string counter uses
  checked `python3` and reports an unestablished count as a failed assertion instead of a
  vacuous zero. (#584)
