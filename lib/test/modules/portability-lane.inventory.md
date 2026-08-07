# macOS Bash 3.2 portability-lane module inventory

This inventory records the provenance of the focused macOS Bash 3.2 portability-lane
module (issue #1277). It is a navigation aid, not a second source of behavior:
`portability-lane.sh` owns the executable assertions, and the complete suite calls the
same module through `module-harness.sh`'s `devflow_run_full_suite_module` boundary. The
`lib/test/run.sh` call site is registered under the `#1277 macOS Bash 3.2 portability
lane` box comment.

Source baseline: this is a **new module authored for issue #1277**, not an extraction
from `lib/test/run.sh` — every component it drives (`lib/shell-surface-registry.json`,
`lib/test/check-shell-surface-totality.py`, `scripts/classify-portability-risk.py`,
`scripts/run-bash32-fixtures.py`, `lib/test/gate-portability-result.sh`) is new in the
same change, so there was no prior in-`run.sh` section to carry forward. No sibling
candidate was left behind in `lib/test/run.sh`.

Its assertion floor is recorded once, in
`scripts/workflow-flight-recorder-registry.json`, and enforced on every run by
`lib/test/run-module.sh`; `test_module_runner.py` reconciles that floor against the
`lib/test/run.sh` call-site literal. This inventory deliberately states no exact
assertion count — the registry is the single source, so a count copied here could drift
out of it silently.

Every assertion is behavioural: each component is executed against a planted fixture —
a real git repository with a real index for the totality checker, an executable `gh`
stub reached through the documented `DEVFLOW_GH` override for the classifier, a real
process for the supervisor's watchdog — and judged on its observable output and exit
status. There is no wording-only pin here (issues #375/#666/#810).

## The one thing this module deliberately does not cover

It does **not** run the Bash-3.2 construct fixtures under Bash 3.2. That interpreter
exists on the macOS runner and on a developer's Mac, not on the Linux host this suite is
required to be green on, and a fixture that "passed" by being skipped is the laundering
issue #456 forbids. The construct fixtures' own correctness is established by the lane
itself, on macOS; what this module establishes is that the machinery which *selects*,
*supervises* and *gates* them behaves — including the interpreter precondition, whose
whole job is to refuse a corpus run under the wrong Bash.

| Contract group | Acceptance criterion | Representative contract |
| --- | --- | --- |
| Totality: clean control | AC8 | a registry classifying every tracked shell file passes, and its `OK` line reports the population it reconciled — so a checker that audited nothing cannot present as a clean pass |
| Totality: failure classes | AC10 | one fixture per class, each mutating exactly one thing from the clean control: unclassified, missing-tracked, duplicate (visible only in the source text, since `json.loads` keeps the last of a repeated key), unknown-state, stale-dependency (both the unresolvable-closure and the portable-sources-excluded shapes), glob-leakage, and the schema arms (empty exclusion reason, missing required field, unsupported `schema_version`, unparseable registry) |
| Totality: the live registry | AC8, AC9 | the shipped registry reconciles against the tracked tree, and every live exclusion carries a non-empty reason and a Bash-4-or-later floor |
| Classifier: degraded input | AC6 | each row drives a `gh` stub through `DEVFLOW_GH`: a failed read, an rc-0 unparseable body, evidence bound to a superseded head, a distinct-file tally below `changed_files`, and one filename returned twice with conflicting statuses — every one selects the complete portable population and reports itself unestablished |
| Classifier: decided outcomes | AC7, AC11 | a non-PR event is a decided conservative outcome (established, not degraded); an established population touching no portable surface selects none; the registry, an unclassified shell surface, and a shared dependency each select the complete portable population |
| Classifier: refusal | AC6 | an unreadable registry exits non-zero rather than emitting an empty selection, because a silently empty selection is the under-selection failure the classifier exists to prevent |
| Supervisor: watchdog | AC14 | a fixture that outlives its deadline *and* backgrounds a child yields domain `fail`; the child is what makes this a process-**group** assertion rather than a direct-child one |
| Supervisor: interpreter precondition | AC12 | a non-3.2 interpreter fails before any fixture runs, and the result file leads with the `DOMAIN_RESULT` line the gate reads |
| Supervisor: `not_applicable` | AC15 | a fully-established empty selection is `not_applicable`; the mirror case — an *unestablished* empty selection — never is, because "we could not look" is not "there was nothing" |
| Supervisor: refusals | AC14 | an unusable classifier result, a malformed manifest row, and a manifest declaring no fixtures each refuse to run rather than reporting a clean empty corpus |
| Corpus completeness | AC13 | the manifest and the fixture directory agree in both directions, so neither an orphan fixture nor a row without a fixture can exist; every fixture is tracked executable |
| Aggregator gate | AC16 | the conclusion-by-domain matrix: success+pass and success+established-`not_applicable` are the only greens; success+fail, a failed/cancelled/skipped producer, an unsupplied conclusion, an absent artifact, an artifact with no `DOMAIN_RESULT` line, a token outside the closed set, and a missing artifact path all fail; a two-`DOMAIN_RESULT` fixture proves the last line decides |
| Rendered-workflow boundary | AC1, AC12, AC14, AC16, AC21 | the stable check name is the aggregator job name, the aggregator runs `always()`, the producer runs on macOS with the 15-minute ceiling and invokes `/bin/bash` directly, auto-review depends on the aggregator, and **no** auto-review step gates on its result — so a failed lane still dispatches the review |
