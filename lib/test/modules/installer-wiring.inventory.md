# Installer / workflow-wiring contract module inventory

This inventory records the provenance of the focused installer and workflow-wiring
contract module (issue #695 extraction). It is a navigation aid, not a second source of
behavior: `installer-wiring.sh` owns the executable assertions, and the complete
suite calls the same module through `module-harness.sh`'s `devflow_run_full_suite_module`
boundary.

Source baseline: `93e5cd13` (`origin/main` before issue #695).

The extracted region was one **syntactic** unit in `lib/test/run.sh` — deliberately not a
slice cut at the first and last labelled assertion, which would have carried an orphan
`done` and an unassigned `_wf487`. It began at the `for _wf487 in devflow-implement
devflow; do` loop header that opens the issue #487 workflow-wiring block and ended at the
`rm -rf "$D533"` fixture teardown that closes the issue #533 installer block.

Three helpers the unit depended on — `mint_blk`, `probe_tmp` and `probe_assert` — were
**promoted** (not copied) from `lib/test/run.sh` into `lib/test/module-harness.sh` in the
same change, because uses of all three remain in the monolith and a copy would have
created an uncoupled mirror. The module re-derives `WF` from the harness-provided `LIB`;
`lib/test/run.sh` keeps its own `WF` assignment for the coverage that stays behind.

| Contract group | Former `lib/test/run.sh` coverage | Module destination | Representative contract |
| --- | --- | --- | --- |
| Refresher / wrapper workflow wiring | `#487` wiring rows inside the `for _wf487` loop | `installer-wiring.sh` / wiring section | both writer workflows start the refresher, install the fresh-gh wrapper, and retire it via a pidfile kill, each gated on `vars.DEVFLOW_APP_ID` |
| `/proc` PEM-leak mitigation and step ordering | `#487` / `#491` ordering rows | wiring section | the refresher launches under `env -u DEVFLOW_APP_PRIVATE_KEY` before `nohup`, and starts only after `Checkout repository` |
| Installer seven-output validation | `#533` AC14 rows and the shared `_ENV533` fixture | installer section | each induced failure exits 1 naming its own output; the success arm lands all seven |
| Installer guard recipes and planted defects | `#533` AC10 / AC13 / AC22 rows | installer section | the bare-`DEVFLOW_GH`-export guard, the harness-entry inherited-override clear, and the mutated-installer copies that flip the named assertions RED |
| Fingerprint-comparison symmetry | `#544` rows | installer section | every defeated hash method still defers on the ambient token with the disclosed breadcrumb |
| Workflow-token and secret-file permissions | `#599` AC21 mutation pins | installer section | the version-consolidate App-token seed, the `umask 077` token file, the bad-credential signature, and the review-identity split each flip RED under a mutation that re-introduces the named regression |
| Windows mode-probe arms | `#690` rows and the `_stub690` / `_i690` stderr-only runners | installer section | the `nt`+`666`/`444` and unrecognized-token arms pass on the mode value with a stderr breadcrumb |

Labels the extraction **fully** removes from `lib/test/run.sh` (zero assertions left
behind, so `lib/test/modules/coverage-map.json` attributes them to this module): 533, 690,
599 and 544. Labels it **partially** removes (assertions remain in the monolith, so they
stay `unmodularized`): 487 and 491.

The generic test harness, registry validation, module registration, full-suite
boundary, and module-runner tests stay global so deleting this module cannot also
delete the checks that prove it is selected and executed. The module uses only
`assert_eq`, the harness-provided helpers, and its own domain-private helpers
(`_dfbn`, `_ac10_count533`, `_ac10_wf_count533`, `_i533`, `_stub690`, `_i690`) — it
references no helper that lives only in `lib/test/run.sh`. Its coverage-map file
ownership (`scripts/install-gh-wrapper.sh` → `installer-wiring`) is recorded in
`lib/test/modules/coverage-map.json`.
