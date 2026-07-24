# Experiment-records contract module inventory

This inventory records the provenance of the focused `#431` experiment-records
contract module (issue #746, the measured first modularization tranche). It is a
navigation aid, not a second source of behavior: `experiment-records.sh` owns the
executable assertions, and the complete suite calls the same module through
`module-harness.sh`'s `devflow_run_full_suite_module` boundary.

Source baseline: `2e9283f4` (`origin/main` after issue #745 landed).

The extracted region was one box-comment section in `lib/test/run.sh` — `#431
build-experiment-records.py — the unified experiment record (join)` — of which
all but the deliberately-retained producer-pins tail moved here (see the partial-
extraction note below). Its assertion floor is recorded once, in
`scripts/workflow-flight-recorder-registry.json`, and enforced on every run by
`lib/test/run-module.sh`; `test_module_runner.py` reconciles that floor against the
`lib/test/run.sh` call-site literal. This inventory deliberately states no exact
assertion count — the registry is the single source, so a count copied here could
drift out of it silently.

## The extraction is deliberately partial

The section's trailing `#431 producer pins` block **stays in
`lib/test/run.sh`**. Its `assert_pin_red_under` pins assert against
`lib/efficiency-trace.jq`, `lib/efficiency-trace.sh`,
`.github/workflows/devflow-review.yml`, `lib/open-state-pr.sh` and the
review-and-fix skill bundle — none of which is this assembler's own surface — and
one of them binds the run.sh-global `$MAXI_BUNDLE`. The module therefore ends at
the last assertion belonging to the helper itself.

Consequence, recorded rather than accidental: the `#431` coverage-map label is only
*partially* extracted, so its `run_sh_blocks` owner stays `unmodularized`.
`coverage_map_guard.py` arm 9 excludes partially-extracted labels from its
fully-extracted set by construction, so this is a supported state, not a suppressed
violation.

| Contract group | Former `lib/test/run.sh` coverage | Module destination | Representative contract |
| --- | --- | --- | --- |
| Stubbed assembler drive | `#431` head | `experiment-records.sh` / assembler section | the assembler runs over fixture stores with a `DEVFLOW_GH` stub and a per-scenario repo root |
| Joined record fields | `#431` join rows | join section | each joined field of the unified experiment record resolves from the expected source |
| Config fingerprint | `#431` `config_fingerprint` rows | fingerprint section | the stamp's partial-flag arm, its `None` arm, and the canonical hash |
| Batch failure honesty | `#431` `Tfail` rows | failure section | an all-candidates-failed batch exits non-zero rather than reporting a silent success, and prior store lines are left unchanged |
| Producer pins | `#431 producer pins` | **stays in `lib/test/run.sh`** | the cross-surface `assert_pin_red_under` pins listed above |

The generic test harness, registry validation, module registration, full-suite
boundary, and module-runner tests stay global so deleting this module cannot also
delete the checks that prove it is selected and executed.

Rewrite performed during extraction: none to the assertions — no pin primitive is
used, so nothing needed renaming. One structural change: the monolith recorded a
missing/non-executable `build-experiment-records.py` with a raw
`echo FAIL >> "$RESULTS_FILE"` write; the module reports that same arm through
`assert_eq` instead, the module contract's only sanctioned failure channel, so the
absence lands in the tally as a named RED assertion rather than an anonymous one.
The extracted body keeps allocating and removing its own fixture tree with a bare
`mktemp -d`, exactly as it did inline; the module adds no private root and no EXIT
trap, for the reasons its header records. Coverage-map ownership for the moved labels is
recorded in `lib/test/modules/coverage-map.json`.
