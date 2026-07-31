---
bump: patch
type: Added
---

- **The shell test suite can now be profiled on demand.** CI wall-clock is set by the slowest
  shard, and the `monolith` shard (`lib/test/run.sh` with the module tier skipped) is the long
  pole — but nothing in the tree could answer *where that time goes*, so tuning it meant
  guessing. `lib/test/profile-suite.py` is an opt-in launcher that timestamps the suite's own
  output stream (bash flushes per builtin even through a pipe) and attributes elapsed time along
  three axes: the `echo "…"` section banners, the `#NNN` issue label carried in each assertion
  name — the same unit `lib/test/modules/coverage-map.json` keys its `run_sh_blocks` on, so a
  per-label cost reads directly as "what extracting this block would move off the shard" — and
  the individual assertion, with a best-effort `run.sh` line number for the expensive ones. It
  writes TSV plus a `run.json`, and re-renders a report from an existing profile directory.
  Because it observes the suite from outside rather than adding timing calls to it, no
  assertion, name, order, or emitted tally changes when profiling, and an ordinary run does not
  read this file at all. The time source is `time.monotonic()` in python3, a hard preflight
  prerequisite — never `date` or `bc`, which the preflight does not guarantee.
