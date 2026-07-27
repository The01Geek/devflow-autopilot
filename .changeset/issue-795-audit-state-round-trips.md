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
