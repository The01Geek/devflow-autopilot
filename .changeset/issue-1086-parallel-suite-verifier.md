---
bump: patch
---

### Added

- `lib/test/run-parallel.sh`, an in-run parallel full-suite coordinator for agent
  verification (issue #1086). It derives its launch population from
  `lib/test/run-shard.sh --list-shards`, runs that population concurrently inside the
  current checkout under a bounded `python3`-derived process budget (overridable with
  `DEVFLOW_SUITE_PROCESS_BUDGET`, capped at eight, with the nested Python pool's width
  reserved out of the same budget and exported as `DEVFLOW_POOL_WIDTH`), recombines it
  through the existing `lib/test/shard-tally.py` protocol, retains every shard's
  complete log under an ignored run root, and prints one compact aggregate. It is
  invoked as a bare granted leading token on the cloud tiers and through the
  documented `DEVFLOW_BASH` selection boundary locally.
- A `--detail-cap` option on `lib/test/shard-tally.py combine`, which bounds how many
  entries of each detail class are rendered and announces the omitted count. It
  defaults to uncapped, so CI's aggregator output is unchanged, and it never bounds the
  counts, the pass/fail decision, or the issue-#456 skip-disagreement check.

### Changed

- The final full-suite gate in this repository's `implement`, `review-and-fix` and
  `receiving-code-review` prompt extensions (and its `CLAUDE.md` mirror) now names the
  coordinator. `lib/test/run.sh` remains the serial primitive the `monolith` shard runs
  and the uncovered-surface fallback names, and focused-module iteration is unchanged.
  The local `Verification evidence:` marker now records the coordinator's retained-log
  root instead of a caller-side redirect target.
