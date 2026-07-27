---
bump: minor
---

### Added

- `/devflow:create-issue`'s Step 3.6 state owner gained a `query-boundary` subcommand that
  answers the Step 3.6 → Step 4 boundary decision in one read, carrying the decided line of
  the trigger, convergence, coverage and calibration answers. The four individual queries
  survive and answer exactly as before ([#795](https://github.com/The01Geek/devflow-autopilot/pull/859)).
- Most `issue-audit-state.py` subcommands now print a second and final `next_call=` line
  naming the next legal invocation, with every state-derivable operand filled and every
  caller-supplied operand bare in a `needs=` field. It is a generated suggestion the caller
  reviews before running, never an instruction, and the decided answer line is unchanged and
  stays first ([#795](https://github.com/The01Geek/devflow-autopilot/pull/859)).

### Changed

- Five state-owner subcommands whose round the state uniquely determines —
  `query-next-action`, `record-return`, `record-adjudication`, `record-adjudication-render`
  and `record-coverage` — now execute against the resolved round when `--round` is omitted,
  producing the same answer and exit code as the explicit call. `record-dispatch`,
  `record-creation-epoch`, `record-degraded` and the cross-round id-scoped channels keep the
  flag required, because there it selects an operation rather than naming a
  state-determined round ([#795](https://github.com/The01Geek/devflow-autopilot/pull/859)).
- `render-audit-prompt.py`'s `dispatch-instructions` mode emits the `dispatch-pointer:` line
  on stderr, byte-identical to the line inside the file its stdout wrote, so the standalone
  read-back extraction leaves the Step 3.6 procedure. Its stdout is byte-unchanged
  ([#795](https://github.com/The01Geek/devflow-autopilot/pull/859)).

### Fixed

- `resolve-main-root.sh` now parses `git worktree list --porcelain` with bash builtins
  instead of `head`/`sed`/`grep`. On a host whose `PATH` carries only the
  preflight-guaranteed tools, the previous pipeline emitted `command not found` and fell
  back to `pwd` — which inside a linked worktree is the *worktree* root, not the main root,
  so the bound draft root was silently wrong with no error. Its always-exit-0 contract,
  `pwd` fallback and breadcrumb text are unchanged
  ([#795](https://github.com/The01Geek/devflow-autopilot/pull/859)).
- The `next_call=` channel's suggested invocations are now reconciled against the target
  subcommand's own required-flag set. Three of them — `record-adjudication`,
  `record-coverage` and `record-resolution` — omitted a required flag entirely (neither
  filled nor named in `needs=`), so copying the suggestion was refused by argparse,
  reproducing the accidental-failure class the channel exists to reduce. A test drives
  every rendering arm and diffs the two sets, so a future required flag cannot silently
  desync ([#795](https://github.com/The01Geek/devflow-autopilot/pull/859)).
- A `query-next-action` answer of `dispatch-retry-same-arm` now emits the reason token the
  shipped procedure documents, `dispatch-arm-unestablished`. While that answer was routed
  by neither table it fell through to the generic `next-action-unestablished` tail, so the
  documented token was never the emitted one
  ([#795](https://github.com/The01Geek/devflow-autopilot/pull/859)).
- `query-nonce` — which registers no `--nonce`, existing to recover one after a compaction —
  no longer answers `reason=foreign-nonce` directly beneath the line handing the caller the
  correct nonce. An absent nonce is now reported as `reason=nonce-unsupplied`, distinct from
  a supplied-and-mismatched one ([#795](https://github.com/The01Geek/devflow-autopilot/pull/859)).
- A `next_call=` render failure now prints `next_call=unestablished reason=render-failed`
  rather than no line at all. The broad catch correctly preserved the success exit code but
  dropped the channel's stdout contract, leaving a caller that parses the final line reading
  the command's own decided line instead
  ([#795](https://github.com/The01Geek/devflow-autopilot/pull/859)).
- `render-audit-prompt.py`'s `_abs_path` single-line check is now total over
  `str.splitlines()`. It tested only `\n`/`\r`, while every downstream consumer splits with
  `splitlines()`, which also breaks on `\v`, `\f`, `\x1c`–`\x1e`, `\x85`, `U+2028` and
  `U+2029` — so a path carrying one of those passed the guard and still became two lines in
  the rendered block, the exact shape the guard exists to refuse
  ([#795](https://github.com/The01Geek/devflow-autopilot/pull/859)).
- `record-adjudication-render` is no longer listed in the unconditional ordered call
  sequence. The state owner *refuses* it with `no-records` on a round that graded no
  advisory or invalid finding, so the sequence prescribed a call that cannot succeed on the
  clean path; the derived unconditional-invocation count moves from 19 to 18
  ([#795](https://github.com/The01Geek/devflow-autopilot/pull/859)).
