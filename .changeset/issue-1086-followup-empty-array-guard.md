---
bump: patch
type: Fixed
---

- **`lib/test/run-parallel.sh` now guards the aggregation step's empty-array expansion.**
  `TALLY_ARGS` is empty when no shard produced a tally — every shard failed to launch, or
  every one died before writing one — and on bash 4.0 through 4.3 a bare
  `"${TALLY_ARGS[@]}"` under `nounset` aborts as an unbound variable, replacing the
  coordinator's own named diagnostic with a raw interpreter error. It now uses the
  `${arr[@]+"${arr[@]}"}` guarded form already used elsewhere in the tree, so that host
  reaches the same named refusal and the same aggregate line. The exit status was
  non-zero either way, and bash 4.4+ is unaffected. (#1099)
