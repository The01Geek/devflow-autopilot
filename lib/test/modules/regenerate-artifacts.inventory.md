# Regenerate-artifacts contract module inventory

This inventory records the provenance of the focused regenerate-artifacts contract
module (issue #619). It is a navigation aid, not a second source of behavior:
`regenerate-artifacts.sh` owns the executable assertions, and the complete suite calls
the same module through `module-harness.sh`'s `devflow_run_full_suite_module` boundary.

Provenance: **new module, issue #619** — not an extraction from `lib/test/run.sh`.
The subject under test, `lib/test/regenerate-artifacts.py`, ships in the same PR, so
there is no former `run.sh` location to map back to.

## What the module covers

| Contract group | Module assertions | Representative contract |
| --- | --- | --- |
| Clean-tree pass | A1 | the live checkout exits 0 with a per-row clean line for all five rows |
| Mechanical row | A2, A2b, A2c | planted manifest drift regenerates and exits 1; a second run is idempotent; a closure error is an exit-1-forcing judgment item naming the closure data; a marker-less exit 1 (a traceback) routes to exit 2 instead of masquerading as a judgment item |
| Judgment rows + write scope | A3 | two drifts planted simultaneously are both reported by one invocation, and the four workflow files, `lib/review-profile.tokens`, `lib/test/prompt-mass-baseline.json`, and `docs/review-bundle-budget.md` are byte-unchanged afterward |
| Registry surface | A4 | `--list` names all five artifacts and its watch list equals the disk-derived review-bundle membership |
| Exit-code contract | A5, A5b | a launch failure and an out-of-declared-set exit both reach exit 2, and exit 2 takes precedence over a concurrent judgment item |
| Budget row | A6, A6b, A6c | an underivable change set degrades to `unestablished` and forces no exit state; an **untracked** bundle member still trips the judgment item; a branch that already updated the record runs clean |
| Helper content | header pins | the registration rule and the disclosed non-goals ship as artifact content, and the helper stays stdlib-only |

## Fixture discipline

Every planted-drift assertion runs against a temp fixture root built from a single
pristine repository image (`cp -R` of `lib`, `scripts`, `skills`, `docs`, `.devflow`,
`.github`, then `git init` plus a synthetic `refs/remotes/origin/main`). The image is
built once and copied per assertion because the generators resolve their roots from
`__file__` or an argv root, so a partial tree would exercise the wrong closure.

Each fixture-root assertion additionally asserts the **live** checkout's
`scripts/devflow-cloud-writer-contract.json` is byte-unchanged. Live-tree confinement
is asserted, never assumed from the generators' current `__file__`-based root
resolution: a future generator migrating to `git rev-parse --show-toplevel` root
resolution (the #295 direction) would break that confinement silently, and an
interrupted live-tree mutate-and-restore would leave a self-consistent corrupted
asset+manifest pair on disk that the issue-543 verify gate would then certify green.

The module uses only `assert_eq` plus its domain-private helpers (`_ra_fixture`,
`_ra_run`, `_ra_has`, `_ra_live_unchanged`, `_ra_cmp`) and the namespaced
`devflow_module_pin_count` from `module-harness.sh` — it references no monolith
`lib/test/run.sh` helper. The coverage-map ownership for
`lib/test/regenerate-artifacts.py` is recorded in `lib/test/modules/coverage-map.json`.
