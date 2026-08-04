# Parallel-suite-runner module inventory

This inventory records the provenance of the focused parallel-suite-runner module
(issue #1086). It is a navigation aid, not a second source of behavior:
`parallel-suite-runner.sh` owns the executable assertions, and the complete suite
calls the same module through `module-harness.sh`'s `devflow_run_full_suite_module`
boundary.

Unlike the extraction tranches that preceded it, this module was **authored new**
rather than moved: `lib/test/run-parallel.sh` did not exist before this change, so
there is no former `lib/test/run.sh` region to cite. The module was written RED-first
against the not-yet-existing coordinator and driven to green as it was implemented.
Its assertion floor is recorded once, in
`scripts/workflow-flight-recorder-registry.json`, and enforced on every run by
`lib/test/run-module.sh`; `test_module_runner.py` reconciles that floor against the
`lib/test/run.sh` call-site literal. This inventory deliberately states no exact
assertion count — the registry is the single source, so a count copied here could
drift out of it silently.

## What the module drives, and what it deliberately does not

Every assertion drives the coordinator against a **synthetic shard dispatcher** planted
in a fixture tree. The real shard population is never launched from inside a registered
module: a shard runs modules, so a real-population invocation here would fork a whole
second suite underneath the shard running this file. The coordinator refuses exactly
that (its reentrancy guard), and this module pins both limbs of that guard — the
refusal and the fixture carve-out that keeps the module runnable from inside a shard.

`lib/test/shard-tally.py` is **not** mocked. The fixture dispatchers write their tallies
through the real extractor, so the aggregation contract under test is the shipped one,
and the `--detail-cap` group drives `combine` directly rather than only through the
coordinator.

The serial-versus-parallel comparison over the real population is deliberately outside
the registered module set; it is a maintainer measurement recorded in the issue workpad,
not a suite assertion.

| Contract group | Module destination | Representative contract |
| --- | --- | --- |
| Population and derivation | population section | the launch roster is the dispatcher's returned list, so a dispatcher returning names the coordinator has never heard of still launches them |
| Overlap, budget, and the nested-pool reservation | population section | shards overlap at budget two and eight; width one is strictly serial and still complete; the `python-pool` reservation is exported only to the shard that owns it, and a non-positive `DEVFLOW_SUITE_PROCESS_BUDGET` override is refused rather than honoured |
| Same-checkout isolation | population and isolation sections | each shard gets its own tally directory and a `TMPDIR` **outside** the checkout, so a fixture tree a shard builds with `mktemp -d` is not inside a git working tree; consecutive runs allocate distinct run roots and a planted stale sibling tally never reaches the aggregate |
| Failure contract | failure section | an empty population, a malformed or duplicated shard name, an unlistable dispatcher, a launch failure, a crashed shard, a shard killed *after* writing a clean tally, a missing or malformed tally, and a skip-detail disagreement each produce a non-zero aggregate with a named diagnostic |
| Signal handling | signal section | `HUP`/`INT`/`TERM` after registration exits 1 and reaps every launched shard; a signal parked in the launch window is replayed rather than swallowed |
| Output contract | output section | a clean run states the combined result, the roster and the retained-log root without replaying the shard's assertion log; 25 entries render the cap plus an omitted count while the complete log survives under the retained run root |
| Detail cap, driven directly | cap section | the helper's uncapped default (CI's aggregator path) renders every entry with no omitted line, a population exactly at the cap announces no omission, a negative cap is uncapped, and capping never turns a failing aggregate green |
| Command shape | shape section | the bare leading token is the complete agent-facing command; a second argument and an unknown argument are refused by their own guards; `--help` renders operative content rather than an empty sentinel selection; an invocation-layer bash selector reaches the same coordinator |
| Generated-artifact preflight (issue #1244) | preflight section | the coordinator runs a read-only preflight (resolved through the `DEVFLOW_ARTIFACT_PREFLIGHT` override, in the `DEVFLOW_SHARD_DISPATCHER` style) before launching any shard: a clean preflight launches the shards and completes; a positively-attributed drift launches **no** shard, exits non-zero and prints the remedy; an exit-2 (uncheckable) preflight, a crashing preflight (traceback, exit 1, no drift marker) and an explicitly-empty override each fail open — the shards still run — so an unusable check never blocks the suite |
| Run root | run-root section | an unusable checkout root falls back to `TMPDIR` and says so, both roots unusable refuses by name and claims no result, and an exhausted candidate name space refuses by name |
