---
bump: patch
---

Reconcile `shard-tally.py combine` against the true shard partition by name (#1289, PR #1293)

`combine` gains an optional `--require-shards` naming the shard partition a recombination must cover. It is checked by shard *name*, not only by the caller-supplied `--expect` count, so a recombination over a subset that satisfies `--expect` now fails closed naming the missing shard(s) instead of printing a whole-suite-shaped green summary. The parallel coordinator `run-parallel.sh` feeds it the authoritative `run-shard.sh --list-shards` population. `--expect 0` remains the documented explicit opt-out, and omitting the new flag leaves existing output unchanged.
