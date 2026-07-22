# Harness Python-guards module inventory

This inventory records the provenance of the focused harness-python-guards module
(issue #707). It is a navigation aid, not a second source of behavior:
`harness-python-guards.sh` owns the executable assertions, and the complete suite
calls the same module through `module-harness.sh`'s `devflow_run_full_suite_module`
boundary.

Source baseline: `607ec800` (`origin/main` before issue #707).

The extracted region was five separate driver blocks in `lib/test/run.sh`, each one a
monolith-only Python guard whose **subject is a single code unit** and whose
**verification is self-contained** — the extraction-eligibility criterion issue #707
states. They ran between the `create-issue-contract` boundary call and the
`issue #546: issue-audit-state.py` banner; they are moved, not duplicated, so the
complete suite now reaches them only through the boundary call that replaced them.

| Covered guard | Former `lib/test/run.sh` location | Module destination | Representative contract |
| --- | --- | --- | --- |
| `scripts/render-audit-prompt.py` (`lib/test/test_render_audit_prompt.py`) | the `#600 create-issue audit-prompt renderer` banner block | `#600` section | the renderer's focused Python tests pass, and the two source-shape pins backstop `test_R9_statelessness` (writes no file, reads no stdin) |
| `scripts/verification_baseline.py` (`lib/test/test_verification_baseline.py`) | the `verification-launch baseline analyzer (issue #527, Wave 1)` banner block | `#527` section | the analyzer's focused Python tests pass, it carries no subprocess/shell-out spelling, and the two registry facts it depends on are present |
| `scripts/verification-flight.py` (`lib/test/test_verification_flight.py`) | the `single-flight verification coordination ledger (issue #528, Wave 2)` banner block | `#528` section | the banned-exec-spelling sweep derived atomically from its single source, the declared state sets, and the three-workflow coupled grant invariant |
| `scripts/reception_identity.py` + `scripts/reception-record.py` (`lib/test/test_reception_identity.py`) | the `receiving-review session artifact producer (issue #668)` banner block | `#668` section | the pair's focused Python tests pass, the library stays importable/stdlib-only, and the CLI imports the library rather than re-implementing the derivation |
| `lib/test/coverage_map_guard.py` (`lib/test/test_coverage_map_guard.py`) | the `issue #591: coverage-map ratchet guard` banner block | `#591` section | the live-tree ratchet over the shipped tree + map is clean, and the guard's arms pass over synthetic fixtures |
| — (added by issue #707) | new | `#707` planted-defect control | a coverage-map drift planted in a synthetic git fixture under the module's private root turns the coverage-map guard RED and names the drifted unit, with the undrifted fixture asserted clean as the control arm. It is a positive control for that guard specifically — the other four covered guards' assertions are clean-tree and absence-grep checks with no planted-failure arm of their own |

## Deliberate exclusions (Python guards that stay in `lib/test/run.sh`)

**The population this table is complete over** is every Python entry point under
`lib/test/` the complete suite drives — directly from `lib/test/run.sh`, or through a
guard or module `lib/test/run.sh` drives. Each is excluded for a stated reason, not
by omission; the criterion is the issue's own — a guard is extraction-eligible when its
subject is a specific code unit *and* its verification is self-contained (it does not scan
a whole population or test the module system itself).

| Guard | Reason it is not extracted |
| --- | --- |
| `lib/test/test_module_runner.py` | It tests the focused-module runner itself — module registration, the registry-floor ↔ call-site coupling, and the per-module contracts. A module that ran it would be circular: deleting the module could delete the check that proves modules are selected and executed. |
| `lib/test/test_module_harness.py` | Same circularity: it tests the full-suite boundary a module is executed through. Its driver block also owns a legitimate `skip … host-capability` arm for the signal matrix, and **modules may not self-skip**, so the block cannot move into one. |
| `lib/test/pin-corpus-lint.py` | A whole-tree meta-guard: it scans the pin corpus across the repository rather than verifying one code unit, so it fails the self-containment half of the criterion. |
| `lib/test/prompt-mass-census.py` | A whole-tree meta-guard over every prompt surface and the census baseline. |
| `lib/test/rb-figure-partition.py` | A whole-tree meta-guard over the governed review-bundle figures. |
| `lib/test/lint-gh-api-repo-path.py` | A whole-tree meta-guard over every tracked-and-unignored surface. |
| `lib/test/cloud_writer_contract.py` | A whole-tree meta-guard over the cloud-writer reachability closure and its runtime manifest. It is not driven from `lib/test/run.sh` at all — the `regenerate-artifacts` module already carries it — so it is out of scope here twice over. |
| `lib/test/check-review-retrigger-coverage.py` | A population scanner: it enumerates every PR-gating workflow under `.github/workflows/` and asserts the re-trigger list is a superset. Its subject is that whole population, not one code unit. |
| `lib/test/extract-command-heads.py` | A whole-bundle scanner over every ```bash fence across the skill surfaces, driven against several allowlists. |
| `lib/test/extract-command-shapes.py` | Same shape: a whole-bundle command-shape scan, not a single-unit verification. |
| `lib/test/lint-issue-body-refetch.py` | A whole-tree lint over every cut-over site. |
| `lib/test/validate-frontmatter.py` | A population scanner over every `agents/*.md` and `skills/**/SKILL.md` frontmatter block. |
| `lib/test/test_python_scripts.py` | Pure-function tests spanning many `scripts/` units at once — its subject is not a single code unit. |
| `lib/test/normalize-verdicts-test.py` | Eligible in isolation, but its `run.sh` driver is **not**: the `#556` block interleaves this helper's unit run with prose pins over three `agents/*.md` files and a review phase file, so the block's subject is multi-surface. Extracting only the unit-test line would split a block — worse than leaving it whole (the no-duplication rule). |
| `lib/test/test_prompt_mass_census.py` | Same block-level reason: its driver is the `#551` block, whose live-tree subject is `prompt-mass-census.py` — an already-ineligible whole-tree meta-guard — with this unit run as one assertion inside it. |

## Shared-label routing caveat

`coverage-map.json`'s `run_sh_blocks` entry carries a single `owner` string, so a label
two modules both assert can name only one of them. That is live here for `#600`: this
module holds the render-audit-prompt driver, while `create-issue-contract.sh` also
asserts `#600`, and the guard's `--fix` attributes the label to the latter. Route a
`#600` change by the `files` entry for `scripts/render-audit-prompt.py` (which names
this module), not by the `run_sh_blocks` label. Repair the map with
`python3 lib/test/coverage_map_guard.py . --fix`, never by hand.

`#707` is split the **other** way and stays `unmodularized`: most of that label's
assertions are the Part-B prose pins in `lib/test/run.sh`, and only the planted-defect
control lives here — so a `#707` change is not covered by running this module alone.

`#591` is split the same way and likewise stays `unmodularized`: this module carries the
ratchet guard's live-tree invocation and its unit test, while the label's surface-presence
pins and the pin-corpus module-coverage block remain in `lib/test/run.sh`. A maintainer
routing a `#591` change by the `run_sh_blocks` label alone reads `unmodularized` and runs
the complete suite, unaware this module covers part of it — so route by the `files` entry
for `lib/test/coverage_map_guard.py` and expect both surfaces to need attention.

The generic test harness, registry validation, module registration, full-suite
boundary, and module-runner tests stay global so deleting this module cannot also
delete the checks that prove it is selected and executed. The module uses the helpers its
sourcing contract provides — `assert_eq` from the **caller** (both `lib/test/run.sh` and
`lib/test/run-module.sh` define it), plus `devflow_run_focused_python_test` and
`devflow_module_allocate_owned_directory` from `lib/test/module-harness.sh` — and
references no helper that lives **only** in `lib/test/run.sh`. Its coverage-map ownership (the five extracted subjects' `files` entries) is
recorded in `lib/test/modules/coverage-map.json`.
