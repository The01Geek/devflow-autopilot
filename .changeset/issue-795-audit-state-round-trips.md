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
- `init --nonce` over an unloadable state now routes by whose input is bad. Both arms
  ended in "omit `--nonce` for a cold start" — the correct remedy when the state file is
  genuinely absent, but a Route-B remedy under a Route-C condition when the file is
  present-but-unreadable, where a cold start silently discards the recorded state. The two
  cases are now separate breadcrumbs ([#795](https://github.com/The01Geek/devflow-autopilot/pull/859)).
- Corrected three prose claims stronger than what the code establishes: the lifecycle
  checker's fail-closed guarantee is scoped to "not empty" and does not exclude a
  degenerate-but-nonzero paragraph; the dispatch-pointer's unconditional rendering is backed
  structurally by the template's single unconditional render block, not by an executable
  test that samples one invocation; and `resolve-main-root.sh`'s builtin parse loop diverges
  from the retired `head -n 1` on input git does not emit
  ([#795](https://github.com/The01Geek/devflow-autopilot/pull/859)).
- The `next_call=` caller-intent classification now keys on the subcommand being
  **rendered**, not the one doing the rendering. Keyed on the emitter the guard could never
  fire: `query-arm` rendering a `record-dispatch` call filled `--round` from state and
  omitted it from `needs=`, handing the caller a pre-decided branch discriminator — the
  fail-open that class exists to prevent. It was inert only because every call site passes
  `None` for that operand ([#795](https://github.com/The01Geek/devflow-autopilot/pull/859)).
- `record-dispatch`'s file-arm suggestion now renders `--draft-file`. The requirement is
  arm-conditional and enforced in the command body, so a reconciliation reading argparse
  `required=True` could not see it, and the most common lifecycle path published a
  suggestion that refuses when copied. The reconciliation now also runs the tool's own
  printed suggestion and requires it not to refuse
  ([#795](https://github.com/The01Geek/devflow-autopilot/pull/859)).
- The lifecycle guard now **refuses** a subcommand-shaped token in the ordered sequence that
  the parser does not register, instead of silently dropping it. Skipping is selection, not
  validation: a typo lowered the derived figure by one while the success line still claimed
  "every one a registered subcommand"
  ([#795](https://github.com/The01Geek/devflow-autopilot/pull/859)).
- New reconciliation arm: every `_NEXT_ACTIONS` member must be routed by one of the two
  `next_call=` tables, with no dead routing entry. This is the check whose absence let the
  `dispatch-retry-same-arm` token mismatch ship
  ([#795](https://github.com/The01Geek/devflow-autopilot/pull/859)).
- `init --nonce` discriminates absence from unreadability on the load failure's own
  `__cause__` rather than a follow-up `Path.exists()`, which swallows every `OSError` — so a
  file behind a permission-denied parent read as absent and was routed to the cold start the
  arm exists to prevent ([#795](https://github.com/The01Geek/devflow-autopilot/pull/859)).
- The derived per-round unconditional call count is now **pinned** at 18 rather than only
  shape-checked and printed, so an added unconditional call turns the suite RED as the
  criterion requires ([#795](https://github.com/The01Geek/devflow-autopilot/pull/859)).
