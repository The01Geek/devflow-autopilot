---
bump: patch
type: Changed
---

Extract the `scripts/issue-audit-state.py` audit-lifecycle drivers out of `lib/test/run.sh` into a new focused test module, `lib/test/modules/issue-audit-state.sh`, routed to the `modules-rest` CI shard. The block is moved, not duplicated: the complete suite reaches its 230 assertions through the `devflow_run_full_suite_module` boundary, so the recombined tally is unchanged while the `monolith` shard's wall clock drops by that block's cost. A change scoped to the create-issue Step 3.6 state owner is now verifiable with `lib/test/run-module.sh issue-audit-state`. As a shared prerequisite, the `git_sandbox` test-isolation helper moves from `lib/test/run.sh` into `lib/test/module-harness.sh` — the same promotion `probe_tmp` already had — so extracted modules can allocate throwaway git repositories through it. (#992)
