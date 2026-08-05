---
bump: patch
---

Stall backstop: record when a terminated implement run left an empty remote branch.

When a cloud `/prflow:implement` run ends abnormally, the trailing `Stall backstop`
step now records on the workpad whether any commit actually reached the run's remote
branch. A branch that is zero commits ahead of its base gets an explicit "empty
branch" statement so it no longer reads as a partially-completed attempt; a branch
that carries work gets no such statement (the negative control); and a state that
cannot be established (unreachable remote, unavailable branch name, or a failed
query) is recorded as unestablished rather than collapsed onto "no commit". The
three-valued decision lives in `scripts/record-empty-branch.sh` beside the step —
`scripts/stall-backstop-decide.sh` stays pure — and it is best-effort: a write
failure warns and never changes the step's exit arm, coexisting with the existing
`💥 Failed` / `🛑 Cancelled` terminal flips.
