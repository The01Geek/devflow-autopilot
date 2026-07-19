# Capability-profiles contract module inventory

This inventory records the provenance of the focused capability-profiles contract
module (issue #591 seed extraction). It is a navigation aid, not a second source of
behavior: `capability-profiles.sh` owns the executable assertions, and the complete
suite calls the same module through `module-harness.sh`'s `devflow_run_full_suite_module`
boundary.

Source baseline: `dc8fa010` (`origin/main` before issue #591).

The extracted region was one contiguous block in `lib/test/run.sh` — the issue #561
capability-profile manifest-generator coverage (`lib/generate-capability-profiles.py
--check`), landed by PR #588. It began at the `#561 capability-profile manifest
generator` banner and ended after the PR #588 review-follow-up `T13` hardening rows.

| Contract group | Former `lib/test/run.sh` coverage | Module destination | Representative contract |
| --- | --- | --- | --- |
| Clean-pass + stdlib-only | `#561` block head (`T2/T10`, `T11`) | `capability-profiles.sh` / clean-pass section | `--check` on the committed tree exits 0 with empty stdout; generator imports no `yaml` |
| Manifest adversarial matrix | `T6` rows + reviewer-boundary row | manifest matrix section | the config-JSON six-shape convention over every manifest read; a group-content edit cannot widen the reviewer silently |
| Region adversarial matrix | `T7` rows | region matrix section | the parser over hand-corruptible workflow text fails closed with a named breadcrumb, target bytes unchanged |
| Planted-defect controls | `T3`/`T4`/`T5` rows | planted-defect section | a deleted region token, an un-regenerated manifest token, and a flipped banner digit each turn `--check` RED |
| Directional diff + idempotency | `T12`, `T1` | determinism section | `--check` names the workflow-side token and the add-to-manifest remedy; the generator is idempotent and locale/cwd-deterministic; committed == generated |
| No-runtime-read + PR #588 hardening | `T8`, `T13a–T13q` | runtime-read + hardening section | no workflow reads policy from the manifest at run time; duplicate-anchor / narrow-direction / unreadable-input fail-closed guards |

The generic test harness, registry validation, module registration, full-suite
boundary, and module-runner tests stay global so deleting this module cannot also
delete the checks that prove it is selected and executed. The module uses only
`assert_eq` plus two domain-private helpers (`_cap_fail`, `_cap_noncomment_hits`) —
it references no monolith `lib/test/run.sh` helper. The seed's coverage-map ownership
(`lib/generate-capability-profiles.py` → `capability-profiles`) is recorded in
`lib/test/modules/coverage-map.json`.
