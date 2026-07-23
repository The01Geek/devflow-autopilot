---
bump: patch
---

Run the test suite's focused Python suites through a bounded concurrent pool.

`test_module_runner.py`, `test_prompt_mass_census.py`, and `test_python_scripts.py`
now execute concurrently in a `min(os.cpu_count() or 1, 4)`-wide pool
(`devflow_pool_open`/`devflow_pool_join` in `lib/test/module-harness.sh`), overlapping
the long pole with the last module boundary and the shell tail. The full-suite signal
handler is generalized from a single scalar child slot to a run-wide live-child
registry so one delivered signal terminates every in-flight child. Measured on an
18-core host, the full suite drops from ~649s to ~572s (~12%). No behavior change for
consumers — this is test-infrastructure only (PR #733, issue #720).
