# issue-audit-state module inventory

This inventory records the provenance of the focused `issue-audit-state` module. It is a
navigation aid, not a second source of behavior: `issue-audit-state.sh` owns the
executable assertions, and the complete suite calls the same module through
`module-harness.sh`'s `devflow_run_full_suite_module` boundary.

Source baseline: `4ccde838` (`origin/main` before this extraction).

The extracted region was a **single contiguous banner block** in `lib/test/run.sh` — the
`issue #546: issue-audit-state.py — the create-issue audit-lifecycle state owner`
section, which ran between the `harness-python-guards` boundary call and the
`devflow_python_suite_pool_join` call. It is moved, not duplicated: the complete suite
now reaches it only through the boundary call that replaced it, and the module's
230 assertions are exactly the 230 the monolith used to execute there.

## Why this block

`scripts/issue-audit-state.py` is the lifecycle owner for `/devflow:create-issue`
Step 3.6 — transition legality, round numbering and round kind, arm routing, budgets and
bounded retries, digest and sentinel comparison, offer triggers, override records,
presentation eligibility and the audit-summary field set. Its drivers are self-contained
CLI round trips over throwaway git repositories, so a change scoped to that CLI is
verifiable with `lib/test/run-module.sh issue-audit-state` instead of the full suite.

## Coverage groups

Assertion-name prefixes, which are the greppable handles for each group:

| Group (assertion-name prefix) | Labels carried | Representative contract |
| --- | --- | --- |
| `cli_roundtrip_restricted_path` | `#546` `#548` `#603` `#743` | the end-to-end round trip `init` → `query-arm` → `record-dispatch` → `record-return` → `query-next-action` / `query-convergence` → `record-adjudication` → `record-revision` → `query-eligibility` → `query-findings` → `record-resolution` → `query-summary`, driven under a PATH containing only the preflight binaries (which also proves the CLI derives nothing through a non-preflight PATH tool), plus the `#743` adjudication-render records and the `#603` REVISE-latest / re-emitted-finding rows |
| `issue #889` (inside the round trip) | `#889` | the ledger records a per-finding `quoted_draft_line` coordinate when supplied and omits the key when not, and the committed `states/` fixture round-trips through a `read_state` over a file the state owner really wrote |
| `digest_filter_mode_rows` | `#546` | the digest filter-mode matrix, including CRLF inputs |
| stale pre-cutover `.md` event log | `#546` | a stale pre-cutover event log is inert |
| `query_exit_contract_matrix` | `#546` | the exit-code contract every `query-*` subcommand answers with, over decided and undecided states |
| `reinit_force_rows`, `init_foreign_nonce_rows` | `#546` | `init --force` re-initialization, and the refusal of a foreign nonce |
| `embed_arm_emit_rows` | `#546` `#709` | the embed-arm emission rows, including the deliberately withheld clean ground |
| `emit-body` gating | `#546` | `emit-body` is gated rather than freely callable |
| `creation_binding_rows` | `#546` | `record-creation-epoch` binding rows and the attestation arms |
| `override_attestation_rows`, `override_precondition_rows` | `#546` `#611` | override records and their attestation rows, plus the precondition matrix that gates them and the `#611` tampered-bytes refusal breadcrumbs |
| `next_action_budget_rows`, `user_round_cap_rows` | `#546` | the next-action budget and the user-chosen round cap |
| `illegal_transition_rows` | `#546` | the transition-legality matrix, including the malformed-state input-shape rows (missing / empty / malformed / array / scalar) |
| `shadow_round_rows`, `conv_shadow_rows` | `#546` | shadow-round recording and convergence across pre-adjudication, revision and resolved states |
| `iter3_hardening_rows`, `iter4_variance_rows`, `iter5_hardening_rows`, `iter6_seam_rows` | `#546` | the iteration-3/5 hardening rows, the iteration-4 variance rows and the iteration-6 seam rows |
| `retry_arm_deadlock_rows` | `#546` | the bounded-retry arms and their sentinel-open / sentinel-close pairs |
| `help_surface_pin` | `#546` `#795` | the rendered `--help` surface (never a source grep on the argparse literals), including the `#795` `next_call=` second line |
| `draft_binding_cli_rows` | `#562` | the draft-binding CLI: tier tokens, absolute-path and worktree-root binding, re-binding refusal, unbound fallbacks, and the readers that ground on the bound file |
| `write_path_crosscheck_rows` | `#569` | the file-arm `--write-path` join: matching, drifted, empty, whitespace-only, wrong-slug, unbound and embed-arm dispatches |

## Deliberate exclusions (sibling candidates left in `lib/test/run.sh`)

The block above is one banner region, so "sibling candidate" here means an *adjacent* or
*label-sharing* block that could plausibly have travelled with it. Each is left behind for
a stated reason, not by omission.

| Candidate | Reason it is not extracted |
| --- | --- |
| The `#548` / `#795` create-issue routing and audit-summary pins in `lib/test/run.sh` | Those labels are **split**: the state owner asserts part of each and the create-issue skill-surface pins assert the rest. Moving only the state-owner half would not make either label module-covered, and moving the skill-surface half would put create-issue prose pins in a module whose subject is a Python CLI. Both labels stay `unmodularized` in the coverage map, which is the truthful answer for split coverage. |
| The `#569` `write_path_crosscheck_rows` block's *skill-side* pins | Only the CLI cross-check rows travelled. The remaining `#569` assertions in `lib/test/run.sh` are over `skills/create-issue/`, a different subject, so `#569` also stays `unmodularized`. |
| `devflow_python_suite_pool_join` (immediately after the block) | It is the monolith's sole join point for the concurrent Python-suite pool and must run in the runner's own shell before the tally is counted. A module runs inside a `( … )` subshell, so joining there would leave the pool unjoined in the parent. |
| The `#161` `git_sandbox` AC3 mutation-proof block | It proves the *harness* helper the fixtures below depend on. Leaving it in `lib/test/run.sh` keeps the proof in the runner that owns the tally the helper writes to, and it resolves the definition this change promoted into `lib/test/module-harness.sh`. |
| `lib/test/test_python_scripts.py`'s `issue-audit-state` pure-function tests | Already routed to the `python-pool` shard; this module is the shell-level CLI driver, and duplicating the Python coverage would violate the no-duplication rule. The coverage map's `files` entry for `scripts/issue-audit-state.py` records both routes. |

## Shared-label routing caveat

`coverage-map.json`'s `run_sh_blocks` entry carries a single `owner` string, so a label
two modules both assert can name only one of them. That is live here for `#546`, `#603`,
`#611` and `#709`: this module holds the state-owner CLI drivers, while
`create-issue-contract.sh` also asserts each of those labels, and the guard's `--fix`
attributes them to the alphabetically first carrier — `create-issue-contract`. Route a
change to the state owner by the `files` entry for `scripts/issue-audit-state.py` (which
names this module), not by the `run_sh_blocks` label. `#562`, `#743` and `#889` are
carried by this module alone and do name it. Repair the map with
`python3 lib/test/coverage_map_guard.py . --fix`, never by hand.

## Contract

The module uses the helpers its sourcing contract provides — `assert_eq` from the
**caller** (both `lib/test/run.sh` and `lib/test/run-module.sh` define it), plus the
harness helpers `lib/test/module-harness.sh` defines: `git_sandbox` (promoted out of
`lib/test/run.sh` by this change, the directory twin of `probe_tmp`) and `record_fail`.
It references no helper that lives **only** in `lib/test/run.sh`. It carries exactly one
private helper, `ias_instructions`, whose only call sites are inside this file; it carries
no pin helper (so no pin-corpus census regeneration is coupled to it) and no `skip` call
(a host-capability condition would have to route through `module_host_capability_skip`;
none applies). Every fixture root is allocated by `git_sandbox` under `$TMPDIR` and
removed by its own block's trailing `rm -rf`, so the module writes nothing into the
repository working tree. Its shard destination — `modules-rest` — is encoded in
`lib/test/run-shard.sh`'s `_shard_modules`.
