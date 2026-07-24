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
| Judgment rows + write scope | A3, A5d | planted capability drift is reported by one invocation, and every judgment-gated artifact (the generated workflow literals, `lib/review-profile.tokens`, `lib/test/modules/coverage-map.json`) is byte-unchanged afterward; A5d drives the coverage-map ratchet's own judgment arm |
| Registry surface | A4 | `--list` names every registered artifact |
| Exit-code contract | A5, A5b, A5c, A5g, A5h, A5j, A5k, A5p, A5q, A5r, A5s | an absent generator (interpreter exit 2, the declared-set branch), an out-of-declared-set exit, a genuine `OSError` launch failure, and an unreadable coverage-map all reach exit 2, attributed to their row rather than only to the summary line; exit 2 takes precedence over a concurrent judgment item (asserted with a positive control that the judgment item — a coverage-map ratchet violation — was actually present, and again while the mechanical row legitimately regenerates); an unreadable artifact snapshot routes to exit 2 via run_row's snapshot-read guard, attributed by that branch's own literal (the exit code alone is not evidence — the same fixture also breaks the generator's write); a usage error exits 2 running no row, proven against planted drift. The helper's top-level exception net is **unexercised by design** — no CLI-reachable input raises past the row-level handlers — and no arm claims to cover it |
| Infra-marker discrimination | A5g, A5j, A5k, A5o | **every** judgment row's `infra_markers` are exercised by an input failure of that row's own kind — a malformed capability manifest, an unreadable coverage-map (`[arm4] `), an unreadable module registry (`[arm8] ` — A5o), and the guard's `[input-error]` git arm — each asserted against its row-attributed `INFRASTRUCTURE` line and the **rendered** `matched '...'` discriminator (not the bare payload, which the generator also echoes), so a typo in a marker literal cannot ship green |
| Conflict oracle | the `#655` arms (grep the `#655 ` assertion-name prefix for the live set) | `--list` is the merge-conflict oracle: every registered row emits an in-set `conflict-class` and a non-empty `conflict-recipe`; every registered row's class assignment holds; the `conflict-path` set covers every known generated artifact — including the workflow literals sourced from the capability generator's own `REGIONS` rather than re-enumerated; exactly one `conflict-sibling` line names the reviewer lock. The recipe is the row's reused `policy` field, asserted to be the single source both the batched pass's `governing policy:` output and the `conflict-recipe` emit read, with a zero-count pin forbidding a parallel `conflict_recipe`. A `conflict_class` outside the closed set and an empty recipe each fail closed at bind time with a breadcrumb naming the offence. Every behavioral arm mutates a *fixture copy* of the helper and re-runs `--list` there, asserting the pinned output line flips present→absent — including the round-2 interface mutation, which renames the `generate` subcommand in the tool itself and requires the recipe's command to go RED rather than staying green as a dead substring. Surface-presence pins cover the three byte-identical extension rule copies (extracted heading-to-next-heading, so a drifted body is caught, not just an absent one) and the generic pointer in each of the three in-run conflict arms, plus a zero-count pin keeping the vendored `receiving-code-review` skill free of any DevFlow-internal helper reference |
| Root resolution | A5f | the `git rev-parse` probe is anchored to this checkout, so an invocation from an unrelated repository still resolves this checkout's root — proven via the capability row's `REGIONS`-derived conflict-path set — rather than regenerating that repository's tree |
| Helper content | header pins | the registration rule and the disclosed non-goals ship as artifact content, and the helper stays stdlib-only |

## Fixture discipline

Every assertion that runs a row does so against a temp fixture root — including the
clean-tree arm — never the live checkout. The fixture is a single pristine repository
image copied per assertion: the module reproduces **every tracked blob** the git index
lists (`git ls-files -s -z`, minus the three named skip arms below), file by file at its
own relative path, then `git init`s it
with a synthetic `refs/remotes/origin/main`. It is built once and copied per assertion
because the generators resolve their roots from `__file__` or an argv root, so a partial
tree would exercise the wrong closure.

**Tracked-only is the fixture rule (issue #714).** Completeness is why the module copies
the whole tracked set rather than a hand-picked subset — a subset that missed one entry
would make the pristine image itself drift and silently invalidate every "no other row
drifted" premise. What the image must *not* carry is untracked local state: the previous
builder derived top-level entry **names** from `git ls-files` but copied whole
**directories**, so because `.claude/settings.json` is tracked the entire untracked
`.claude/` tree entered the image and then every per-assertion copy. Nothing untracked
can enter now, so the `__pycache__` / `.ruff_cache` / `.devflow/tmp` prunes that
compensated for it are gone with the loop that needed them.

**Past-time snapshot (macOS, 18 cores, a checkout carrying 1.4 GB under
`.claude/worktrees`, `main` @ `607ec800`, 2026-07-21).** Pristine image 1.4 GB → ~34 MB;
this module 1240.0s → 52.5s; full `lib/test/run.sh` 1850.5s → ~663s. These are recorded
figures from one host, not re-derived on each run: the payload they measure exists only
on a developer checkout that has used `git worktree`, so a lean checkout (CI, a cloud
`/devflow:implement` run) sees no change and must not be cited as evidence either way.

File **modes are set from the index**, not inherited from the working tree, so a
`core.fileMode=false` checkout (git's default on Windows) — where the index records
`100755` while the on-disk bit is absent — builds the same image. Three skip arms are
each taken with their own distinct named stderr breadcrumb and subtracted from the
completeness denominator by name, never failing the build: two non-blob index modes — a
gitlink (`160000`) and a symlink (`120000`) — plus an ordinary blob the working tree
does not carry (tracked-then-deleted), which is a working-tree condition rather than an
index-mode one and so is triaged by its own `[ ! -f ]` guard rather than the mode
`case`. A copy failure and a mode-application failure are each counted on their own
`fail_copy` / `fail_mode` channel — a failure is never a skip, so it can never hide in
the gap between `total` and `copied`; `_ra_summary_balances` asserts that partition.
An unestablished measurement makes *both* the bash builder and the python oracle emit
an `unestablished` sentinel instead of a vacuous zero — a failed `git ls-files` in
either half, or, for the oracle alone, an image directory that is not there — and each
sentinel has a caller that drives it, as do the `fail_copy` channel (a regular file
planted where a nested entry's parent directory must go) and the `fail_mode` channel (a
`chmod` stub exiting 1, shadowed onto `PATH` for the duration of one build only, which
also reproduces the rc-127 absent-`chmod` host). The two structural skip tallies are
additionally pinned to zero against the **live** index, because builder/oracle agreement
alone would let a newly tracked symlink or submodule leave every fixture silently
incomplete while both halves agree about the omission. The symlink index-entry rows are
gated on a runtime `ln -s` capability probe: a `core.symlinks=false` checkout (Windows
without the symlink privilege) omits `link.md` from the fixture and announces the gated
rows on stderr, rather than going RED over a symlink git was never given. Unmerged
paths contribute once, not once per stage. The `#619 pristine fixture …` / `#619 fixture
builder …` assertions check all of this against an independent oracle that re-reads the
index itself, with the temp-repository arms exercised against a real git index rather
than a stubbed `git ls-files`.

**Coupled mirror:** `_ra_build_image` (bash) and `_ra_image_report` (the embedded
python3 oracle) state the same selection policy — mode triage, unmerged-stage
de-duplication, the working-tree `isfile` check — in two languages. That independence is
what makes the oracle a real check rather than a restatement of the builder's own
bookkeeping, and it is also what makes them a coupled pair: a change to the builder's
skip policy must be made in the oracle in the **same commit**, or the oracle keeps
certifying the old policy.

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
