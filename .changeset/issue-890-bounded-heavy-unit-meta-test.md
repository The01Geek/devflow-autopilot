---
bump: patch
type: Changed
---

- **The required `lib + python tests` check no longer runs the pin-corpus authoring gate
  twice per CI run.** The `monolith` shard reached that block through the pooled real-runner
  meta-test for the `harness-python-guards` module, while the `modules-pin` shard ran the
  same module in full, putting the suite's heaviest unit on the critical path twice.
  `lib/test/run-module.sh` gained a `--heavy-units full|smoke` flag (default `full`, refusing
  anything else), and the meta-test passes `smoke` so that one unit runs a single test per
  class. The meta-test proves what it proved before — a real `run-module.sh` invocation,
  exit 0, and an emitted tally equal to the module's registry floor — and the full population
  still runs exactly once per CI run, in `modules-pin`. A bounded run is never silent: the
  runner prints a notice naming the requested mode, and it now **fails** a run whose module
  bounded a heavy unit that `--heavy-units` did not ask for, so a reduction can never land as
  a green tally. (#896)
