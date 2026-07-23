# Prompt-extension-reader contract module inventory

This inventory records the provenance of the focused prompt-extension-reader
contract module (issue #746, the measured first modularization tranche). It is a
navigation aid, not a second source of behavior: `prompt-extension-reader.sh` owns
the executable assertions, and the complete suite calls the same module through
`module-harness.sh`'s `devflow_run_full_suite_module` boundary.

Source baseline: `2e9283f4` (`origin/main` after issue #745 landed).

The extracted region was one contiguous box-comment section in `lib/test/run.sh` —
the section titled `load-prompt-extension.sh (consumer prompt-extension reader)`,
491 lines using `assert_eq` alone and no pin primitive at all. It was
chosen as the tranche's zero-rewrite range: the section referenced exactly one
run.sh-global (`LIB`, which the module contract already binds), defined no function
consumed elsewhere, and called no monolith-only helper, so the assertions moved
verbatim. Its assertion floor is recorded once, in
`scripts/workflow-flight-recorder-registry.json`, and enforced on every run by
`lib/test/run-module.sh`; `test_module_runner.py` reconciles that floor against the
`lib/test/run.sh` call-site literal. This inventory deliberately states no exact
assertion count — the registry is the single source, so a count copied here could
drift out of it silently.

| Contract group | Former `lib/test/run.sh` coverage | Module destination | Representative contract |
| --- | --- | --- | --- |
| Present / absent / empty extension | the AC 1–3 rows | `prompt-extension-reader.sh` / basic-arms section | a present extension prints verbatim and exits 0; an absent one prints nothing and still exits 0 |
| Skill-name validation | the AC 4 rows | name-guard section | a name containing `/` or `..` is refused with exit 2 before the filesystem is touched |
| Unreadable / symlink / permission arms | the AC 5 rows | degraded-fixture section | an unreadable or symlinked extension fails closed rather than printing partial content |
| `--section` selector | AC 8 rows | section-selector section | `--section` emits only the named section, and a missing section is not an error |
| `--section` × name guards | traversal rows | section-selector section | the path-traversal refusal still fires when `--section` is present, so the flag is never a bypass |

The generic test harness, registry validation, module registration, full-suite
boundary, and module-runner tests stay global so deleting this module cannot also
delete the checks that prove it is selected and executed. The module uses only
`assert_eq` — it references no monolith `lib/test/run.sh` helper — and owns its
private fixture root through a `trap _lpe_cleanup EXIT` installed inside the
sourcing subshell. Coverage-map ownership for the moved labels is recorded in
`lib/test/modules/coverage-map.json`.
