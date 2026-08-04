---
bump: patch
---

### Fixed

- The `command` tier (`devflow.yml` — the manual `/prflow:review` and
  `/prflow:review-and-fix` path a collaborator triggers by comment) passed no `settings:`
  input to its Claude step, so the Bash tool's per-command ceiling fell back to Claude
  Code's `BASH_MAX_TIMEOUT_MS` default of 600000 ms (10 min). The prompt extension this
  tier loads names the parallel verification coordinator `lib/test/run-parallel.sh` as
  the run's final whole-suite gate, and that coordinator was measured at ~10.5 min in a
  cloud run — so the mandated command could not complete there: it was killed at the wall
  with no output and the run was pushed onto the slower shard-decomposition fallback to
  redo the same work. The step now sets a bounded 1200000 ms (20 min) ceiling, matching
  the implement tier's existing value so the two agree.
