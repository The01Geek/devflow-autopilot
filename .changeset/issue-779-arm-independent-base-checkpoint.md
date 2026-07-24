---
bump: patch
---

### Fixed

- The Phase 1 base-branch update checkpoint is now **arm-independent**: it runs as the last step of `/devflow:implement`'s §1.4 on every arm — new branch, adopted branch, and landed resume alike — instead of being gated on a variable the resumed path never binds. A re-triggered or backstop-resumed run previously completed its whole cycle against a base snapshot that no longer existed, surfacing only as an unrelated-looking CI failure hours later. A branch that is already current takes the helper's existing `UP_TO_DATE` no-op. (#779)
- Both of Phase 1.4's base fetches now use the same forced refspec `scripts/update-branch-checkpoint.sh` uses (`+refs/heads/$BASE:refs/remotes/origin/$BASE`), so a checkout whose configured refspec is scoped to the feature ref can no longer leave `refs/remotes/origin/$BASE` unadvanced and report a false behind-by 0. (#779)

### Changed

- Phase 4.3 now gates the completion claim on the pre-ready checkpoint: it grades the **first whitespace-delimited field** of the helper's emitted line, records a `--note` naming the observed token before publishing on `UPDATED`/`UP_TO_DATE`/`DISABLED` alike, and refuses both `gh pr ready` and the `Status: Complete` flip — recording `Blocked` naming the observed line — when that field is `UNVERIFIED`, `PUSH_REJECTED`, `MERGE_IN_PROGRESS`, empty, or unrecognized. `CONFLICT` is exempt (it resolves per the inherited contract and the helper is re-invoked), and an invocation the tier refuses to run at all records a degraded reflection and publishes as before. (#779)
- A `CONFLICT` from the Phase 1 checkpoint routes to `Blocked` as needs-human-reconciliation on every arm, because no operand readable at that call site distinguishes the landed-resume arm — whose ahead history no classification has validated. Checkpoints 2, 3 and 4 keep §1.4.1's inherited `CONFLICT` contract unchanged. (#779)
