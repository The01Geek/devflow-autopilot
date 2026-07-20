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
| Clean-tree pass | A1 | a pristine fixture exits 0 with a per-row clean line for every registered row |
| Mechanical row | A2, A2b, A2c | planted manifest drift regenerates and exits 1; a second run is idempotent; a closure error is an exit-1-forcing judgment item naming the closure data; a marker-less exit 1 (a traceback) routes to exit 2 instead of masquerading as a judgment item |
| Judgment rows + write scope | A3, A5d | two drifts planted simultaneously are both reported by one invocation, and every judgment-gated artifact (the generated workflow literals, `lib/review-profile.tokens`, `lib/test/prompt-mass-baseline.json`, `docs/review-bundle-budget.md`) is byte-unchanged afterward; A5d drives the coverage-map ratchet's own judgment arm |
| Registry surface | A4 | `--list` names every registered artifact and its watch list equals the disk-derived review-bundle membership |
| Exit-code contract | A5, A5b, A5c | an absent generator (interpreter exit 2, the declared-set branch), an out-of-declared-set exit, and a genuine `OSError` launch failure all reach exit 2, attributed to their row rather than only to the summary line; exit 2 takes precedence over a concurrent judgment item |
| Budget row | A6, A6b, A6c, A5e | an underivable change set degrades to `unestablished` and forces no exit state; an **untracked** bundle member still trips the judgment item; a branch that already updated the record runs clean; a **renamed** member reports unestablished rather than a false clean |
| Helper content | header pins | the registration rule and the disclosed non-goals ship as artifact content, and the helper stays stdlib-only |

## Fixture discipline

Every assertion that runs a row does so against a temp fixture root — including the
clean-tree arm — never the live checkout. The fixture is a single pristine repository
image copied per assertion: the module enumerates **every top-level tracked entry** from
`git ls-files` (deliberately not a hand-picked subset — a subset that missed one would
make the pristine image itself drift and silently invalidate every "no other row
drifted" premise), prunes build caches, then `git init`s it with a synthetic
`refs/remotes/origin/main`. It is built once and copied per assertion because the
generators resolve their roots from `__file__` or an argv root, so a partial tree would
exercise the wrong closure.

Each fixture-root assertion additionally asserts the **live** checkout's
`scripts/devflow-cloud-writer-contract.json` is byte-unchanged. Live-tree confinement
is asserted, never assumed from the generators' current `__file__`-based root
resolution: a future generator migrating to `git rev-parse --show-toplevel` root
resolution (the #295 direction) would break that confinement silently, and an
interrupted live-tree mutate-and-restore would leave a self-consistent corrupted
asset+manifest pair on disk that the issue-543 verify gate would then certify green.

The module uses `assert_eq` plus its own `_ra_*` domain-private helpers and the
namespaced pin API from `module-harness.sh` (`devflow_module_pin_count` /
`devflow_module_pin_present`) — it references no monolith `lib/test/run.sh` helper. The
helper set is deliberately not enumerated here: an exact list is a mirror-fact that goes
stale on the next helper added, and the authoritative set is the `_ra_*` definitions in
the module itself.

`lib/test/regenerate-artifacts.py` has **no** row in `lib/test/modules/coverage-map.json`
and needs none: `lib/test/` is listed in that map's `exempt_subtrees`, and
`coverage_map_guard.py`'s patterns are depth-1 (`lib/*.py`, `scripts/*.sh`, …), so a
depth-2 path under `lib/test/` is outside the ratchet surface by construction. Its
coverage is this module, registered through the five-part contract above.
