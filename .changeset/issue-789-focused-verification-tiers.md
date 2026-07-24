---
bump: patch
---

### Added

- Focused verification now credits the Python test layer. `lib/test/modules/coverage-map.json`
  gains an optional `focused_test` field recording the `lib/test/test_*.py` file that covers a
  `scripts/*.py` / `lib/*.py` helper, so such a change routes to a focused test instead of the
  full suite. A new `coverage_map_guard.py` arm validates each recorded target as git-tracked,
  `test_*.py`-named, and executable in the index, and reports an unestablished mode set as
  unestablished rather than collapsing it onto either answer ([#789](https://github.com/The01Geek/devflow-autopilot/pull/791)).
- `lib/test/run.sh` prints a named `Failure recap` after its terminal summary on a failing run,
  re-listing each failing assertion's identifier from an on-disk sibling record that every
  tally-writing site appends to. The record covers both output streams, so a failure whose detail went to stderr is
  recapped exactly like one on stdout, and the suite's exit status is preserved through the
  recap. A clean run prints no recap and its summary line is byte-identical to before
  ([#789](https://github.com/The01Geek/devflow-autopilot/pull/791)).
- The focused `lib/test/test_*.py` files and `lib/test/coverage_map_guard.py` are executable and
  granted as direct-leading-token forms in the `implement` capability profile, so the focused
  tiers are invocable on the cloud tier, where the `python3 <script>` interpreter-head shape is
  denied. The grant is implement-only; the review profile is unchanged
  ([#789](https://github.com/The01Geek/devflow-autopilot/pull/791)).

### Changed

- The focused-verification policy is now tiered: a run iterates on the covering focused test when
  one exists; a `run.sh`-resident surface with no covering test uses the full suite for its first
  mid-iteration cycle only, and a second cycle on that same surface extracts a durable module
  instead. The full-suite fallback is a closed set and a run that takes it names which case
  applied ([#789](https://github.com/The01Geek/devflow-autopilot/pull/791)).
- The `#719` local verification capture merges stderr, so the recap's stderr half lands in the
  log ([#789](https://github.com/The01Geek/devflow-autopilot/pull/791)).

### Fixed

- A `lib/test/run.sh` failure arm recorded its FAIL with an in-memory counter that the tally's
  recomputation discarded, so it printed a failure the suite never counted
  ([#789](https://github.com/The01Geek/devflow-autopilot/pull/791)).
