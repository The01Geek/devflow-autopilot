# Regenerate-artifacts contract module inventory

This inventory records the provenance of the focused regenerate-artifacts contract
module (issue #619). It is a navigation aid, not a second source of behavior:
`regenerate-artifacts.sh` owns the executable assertions, and the complete suite calls
the same module through `module-harness.sh`'s `devflow_run_full_suite_module` boundary.

Provenance: **new module, issue #619** — not an extraction from `lib/test/run.sh`.
The subject under test, `lib/test/regenerate-artifacts.py`, ships in the same PR, so
there is no former `run.sh` location to map back to.

## What the module covers

| Contract group | Representative assertions | Representative contract |
| --- | --- | --- |
| Clean-tree pass | A1 | a pristine fixture exits 0 with a per-row clean line for every registered row |
| Mechanical row | A2, A2b, A2c | planted manifest drift regenerates and exits 1; a second run is idempotent; a closure error is an exit-1-forcing judgment item naming the closure data; a marker-less exit 1 (a traceback) routes to exit 2 instead of masquerading as a judgment item |
| Judgment rows + write scope | A3, A5d | two drifts planted simultaneously are both reported by one invocation, and every judgment-gated artifact (the generated workflow literals, `lib/review-profile.tokens`, `lib/test/prompt-mass-baseline.json`, `docs/review-bundle-budget.md`, `docs/review-and-fix-budget.md`) is byte-unchanged afterward; A5d drives the coverage-map ratchet's own judgment arm |
| Registry surface | A4, A4b | `--list` names every registered artifact, and **each** budget row's watch list — extracted by that row's own attributed `budget-watch\t<row>\t` prefix (issue #624) — equals the disk-derived membership of its bundle. The disk sets are derived from the tree, never from `lib/test/run.sh`'s `REVIEW_*`/`RAF_*` shell variables, which are unset under standalone `run-module.sh`. Two registry-derived assertions keep the audit from certifying its own completeness: the roster of rows `--list` emits `budget-watch` lines for must equal the roster actually checked (so a newly-registered budget row nobody checks goes RED instead of shipping unverified), and no member may belong to more than one row (data-driven over every checked row, not a fixed pair). Both guard against a vacuous pass with non-empty preconditions. A4b pins the budget-row shape across the registry — `is_budget_row(row) == (row["argv"] is None)` (the coincidence that predicate's docstring rests on) plus the full key set `budget_row`/`watch_list` consume — and fails closed rather than checking zero rows on an empty registry |
| Exit-code contract | A5, A5b, A5c, A5g, A5h, A5j, A5k, A5m, A5p, A5q, A5r, A5s | an absent generator (interpreter exit 2, the declared-set branch), an out-of-declared-set exit, a genuine `OSError` launch failure, and an unreadable coverage-map all reach exit 2, attributed to their row rather than only to the summary line; exit 2 takes precedence over a concurrent judgment item (asserted with a positive control that the judgment item was actually present, and again while the mechanical row legitimately regenerates); an unreadable artifact snapshot routes to exit 2 via run_row's snapshot-read guard, attributed by that branch's own literal (the exit code alone is not evidence — the same fixture also breaks the generator's write); a usage error exits 2 running no row, proven against planted drift. The helper's top-level exception net is **unexercised by design** — no CLI-reachable input raises past the row-level handlers — and no arm claims to cover it |
| Infra-marker discrimination | A5g, A5j, A5k, A5m, A5n, A5o, A5p2 | **every** judgment row's `infra_markers` are exercised by an input failure of that row's own kind — a malformed capability manifest, a malformed census manifest (`: malformed JSON:`), an **unreadable** census JSON input (`: unreadable:`, driven by making the manifest a directory so the arm needs no permission bits — A5p2), an unreadable coverage-map (`[arm4] `), an unreadable module registry (`[arm8] ` — A5o), and the guard's `[input-error]` git arm — each asserted against its row-attributed `INFRASTRUCTURE` line and the **rendered** `matched '...'` discriminator (not the bare payload, which the generator also echoes), so a typo in a marker literal cannot ship green; A5n pins the per-line scoping by splitting a marker across a newline and requiring JUDGMENT, not a hit |
| Budget rows | the `A6*` and `A5i*`/`A5e` arms (grep the `#619 A`/`#624 A` assertion-name prefixes for the live set — an enumeration copied here would rot on the next arm added) | for the review-bundle row: an underivable change set degrades to `unestablished` and forces no exit state; an **untracked** bundle member still trips the judgment item; a branch that already updated the record runs clean; a **renamed** member reports unestablished rather than a false clean. A6d/A6e mirror the two record-staleness arms for the sibling **review-and-fix** row (issue #624), each pinned on that row's own attributed line and its own record path, and each asserting the review-bundle row stays `clean` on a fixture where only the review-and-fix bundle moved — so neither arm can pass on a fixture where *nothing* was noticed. A5i3/A5i4 pin the new row's own `missing` legs — a renamed `references/` parent and a renamed literal member — which the review-bundle row's A5e/A5i could not reach |
| Root resolution | A5f | the `git rev-parse` probe is anchored to this checkout, so an invocation from an unrelated repository cannot resolve — or regenerate — that repository's tree |
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
namespaced pin API from `module-harness.sh` — it references no monolith
`lib/test/run.sh` helper. The
helper set is deliberately not enumerated here: an exact list is a mirror-fact that goes
stale on the next helper added, and the authoritative set is the `_ra_*` definitions in
the module itself.

`lib/test/regenerate-artifacts.py` has **no** row in `lib/test/modules/coverage-map.json`
and needs none: `lib/test/` is listed in that map's `exempt_subtrees`, and
`coverage_map_guard.py`'s patterns are depth-1 (`lib/*.py`, `scripts/*.sh`, …), so a
depth-2 path under `lib/test/` is outside the ratchet surface by construction. Its
coverage is this module, registered through the module-registration contract
(module file, this inventory, the flight-recorder registry row, the `lib/test/run.sh`
call-site floor, and the explicit `ci.yml` shellcheck listing).
