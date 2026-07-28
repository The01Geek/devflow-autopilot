---
bump: patch
---

### Changed

- The required `lib + python tests` check no longer executes the pin-corpus authoring
  gate twice per run. The `monolith` shard reaches that block through the pooled
  real-runner meta-test for the `harness-python-guards` module, while the `modules-pin`
  shard runs the same module in full — so the heaviest unit in the suite was on the
  critical path twice. The sharded Python test driver now takes an optional population
  mode, and the meta-test drives the module with that one unit bounded to a single test
  per class. The meta-test proves exactly what it proved before (a real `run-module.sh`
  invocation, exit 0, and an emitted tally equal to the module's registry floor), and the
  full population still runs exactly once per CI run in `modules-pin`.
