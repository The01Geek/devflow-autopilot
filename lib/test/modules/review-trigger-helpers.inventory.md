# Review/implement trigger-helper contract module inventory

This inventory records the provenance of the focused review/implement
trigger-helper contract module (issue #746, the measured first modularization
tranche). It is a navigation aid, not a second source of behavior:
`review-trigger-helpers.sh` owns the executable assertions, and the complete suite
calls the same module through `module-harness.sh`'s `devflow_run_full_suite_module`
boundary.

Source baseline: `2e9283f4` (`origin/main` after issue #745 landed).

The extracted region was **11 consecutive box-comment sections** in
`lib/test/run.sh`, 2,058 lines carrying 266 assertions (260 `assert_eq`, 4
`assert_pin_unique`, 2 `assert_pin_red_under`). It ran from the section
`derive-review-verdict.sh (#249 HEAD-scoped, fail-closed verdict deriver)` through
`resolve-command-trigger.sh` inclusive. **It stops there deliberately:** the very
next section defines `react()`, which four later `run.sh` sections still call, so
moving it would strand them. The floor is 258, eight below the measured 266.

| Contract group | Former `lib/test/run.sh` section | Module destination | Representative contract |
| --- | --- | --- | --- |
| Review verdict derivation | `derive-review-verdict.sh (#249 …)` | `review-trigger-helpers.sh` / verdict section | the deriver is HEAD-scoped and fails closed — an unresolvable comment set yields no verdict, never a default pass |
| Review preconditions | `derive-review-preconditions.sh (#304 …)` | preconditions section | branch-freshness and other-CI-green gating, including the unestablished-measurement arms |
| Engine-error parsing | `parse-engine-error.sh (#249 …)` | engine-error section | the execution-log `is_error` parser feeding `engine_is_error` |
| Execution diagnostics | `surface-execution-diagnostics.sh (#329 …)` + `workflow wiring: … (#331)` | diagnostics section | the run summary and permission-denials surfacer honors `DEVFLOW_JQ` and degrades to "No diagnostics available" rather than a bare-`jq` read |
| Execution transcript | `execution transcript artifact: config key + scrub/gate hardening (#409)` | transcript section | the default-OFF polarity and the fail-closed transcript clamp, both proved by mutation |
| Implement trigger | `resolve-implement-trigger.sh`, `dedupe-implement-run.sh` | implement-trigger section | trigger resolution and the single-flight dedupe of an implement run |
| Actor authorization | `authorize-actor.sh (allowed_users filter)` | authorization section | the `allowed_users` filter's allow/deny arms and deny reasons |
| Standalone command routing | `detect-standalone-command.sh`, `resolve-command-trigger.sh` | command-routing section | both the resolver and `review_dedupe` route through the one shared detector, and the detector extraction fails open only under an `if !` guard |

The generic test harness, registry validation, module registration, full-suite
boundary, and module-runner tests stay global so deleting this module cannot also
delete the checks that prove it is selected and executed.

Rewrite performed during extraction: the 4 `assert_pin_unique` calls became
`devflow_module_pin_unique` and the 2 `assert_pin_red_under` calls became
`devflow_module_pin_red_under` — a mechanical 1:1 rename onto the namespaced module
pin API, with the pinned literals, mutations and target paths unchanged. Two run.sh
globals are re-derived in the module header rather than inherited: `TMPDIR` is
redirected to the module's own owned root (the body allocates eleven fixture trees
with bare `mktemp -d`), and `CG` — the `scripts/config-get.sh` resolver path that
five `#329`/`#409` key-read assertions invoke — is bound from `LIB` exactly as the
monolith binds it. Coverage-map ownership for the moved labels is recorded in
`lib/test/modules/coverage-map.json`.
