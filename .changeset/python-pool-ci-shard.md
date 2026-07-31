---
bump: patch
---

### Changed

- CI: the two heavy pooled Python suites (`test_module_runner.py`,
  `test_python_scripts.py`) now run on their own concurrent `python-pool` shard
  instead of inside the `monolith` shard. Profiling the monolith shard with
  `lib/test/profile-suite.py` measured it sitting idle at the issue-#720 pool join
  for ~22% of its wall-clock, waiting for Python work it had run out of shell
  assertions to overlap with. `lib/test/run-shard.sh` now invokes `lib/test/run.sh`
  with `DEVFLOW_SKIP_PYTHON_POOL=1` on the monolith shard and drives the same pool —
  over the same membership, via the single `devflow_python_suite_pool_open` /
  `devflow_python_suite_pool_join` definition in `lib/test/module-harness.sh` — from
  the new `lib/test/run-python-pool.sh` driver. No assertion is added, removed, or
  moved between suites; only which shard counts it changes, and the aggregator's
  `--expect` shard floor rises with the matrix so a missing shard still fails the
  required `lib + python tests` check closed. A plain local `bash lib/test/run.sh`
  is unchanged: the selector is unset, so the pool still opens early and overlaps
  the shell tail.
