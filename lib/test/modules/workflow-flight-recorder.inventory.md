# Workflow-flight-recorder contract module inventory

This inventory records the provenance of the focused workflow-flight-recorder test
module. It is a navigation aid, not a second source of behavior: `workflow-flight-recorder.sh`
owns the executable assertions, and the complete suite calls the same module through
`module-harness.sh`'s `devflow_run_full_suite_module` boundary.

Source baseline: `dc8fa010` (`origin/main` at issue #591; the inventory was added by
#591 so every registered module has one, per `CONTRIBUTING.md`).

Unlike the later contract modules, this module was **authored natively** alongside the
selectable-module machinery (issues #563/#566), not carved out of a pre-existing
`lib/test/run.sh` block — so it has no "former run.sh line-range" origin. Its assertions
were written directly against `scripts/workflow_flight_recorder.py` and the recorder's
documented hook/inventory/analyzer surfaces. The table below records the module's own
coverage groups rather than a former location.

| Contract group | Coverage | Module destination | Representative contract |
| --- | --- | --- | --- |
| Native inventory + observation | `scripts/workflow_flight_recorder.py` read-only inventory | `workflow-flight-recorder.sh` / native-inventory section | UserPromptSubmit observation writes only the start manifest; read-only inventory reports it without importing |
| Explicit import | generalized transcript bundle creation | explicit-import section | import creates the generalized bundle, retains the native final tail, refreshes rather than duplicates on repeat |
| Constrained analysis / launch | analyzer launch flags | constrained-analysis section | launch enables safe mode, print mode, denies permission prompts, and grants only read-only tools (`Read,Grep,Glob`) |
| Focused Python coverage | `test_workflow_flight_recorder.py` | focused-Python section | the recorder's Python unit suite runs green through `devflow_run_focused_python_test` |

The generic test harness, registry validation, module registration, full-suite
boundary, and module-runner tests stay global so deleting this module cannot also
delete the checks that prove it is selected and executed.
