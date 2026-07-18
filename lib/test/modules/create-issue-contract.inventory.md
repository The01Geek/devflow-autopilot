# Create-issue contract module inventory

This inventory records the provenance of the focused create-issue contract module.
It is a navigation aid, not a second source of behavior: `create-issue-contract.sh`
owns the executable assertions, and the complete suite calls the same module through
`module-harness.sh`'s `devflow_run_full_suite_module` boundary.

Source baseline: `553e13da` (`origin/main` before issue #577).

The extracted region was one contiguous block in `lib/test/run.sh` — it began at the
issue #443 audit contract and ended after the issue #559 revision-delta pins. The
issue-#548 evidence-bundle coverage sat interleaved inside that block (between #467
and #465) and reused the same create-issue file variables, so it migrated with the
block; the issue text enumerated eight issues but the contiguous region carried nine.
The unrelated implement coverage before the region and the review-and-fix drift-guard
coverage (issue #199) after it stay in the monolith.

| Contract group | Former `lib/test/run.sh` coverage | Module destination | Representative contract |
| --- | --- | --- | --- |
| Step 3.6 fresh-context audit | `3744–3892` | `create-issue-contract.sh` / issue-#443 section | the FILE/REVISE/DRAFT-UNREADABLE verdict line and the information-diet exclusion |
| Canonical draft-file audit + state-owner cutover | `3894–4220` | issue-#522 and #546 sections | presentation eligibility is the tool's answer; the canonical draft file is the sole draft source |
| Authoring-discipline rules and hardenings | `4222–4384` | issue-#462 and #467 sections | value-comparison observed-output grounding; the universal-quantifier sweep |
| Evidence-bundle sub-pass and actionability | `4385–4435` | issue-#548 section | the evidence-bundle axis floor and the bounded-actionability verdict definitions |
| Multi-state reconciliation, adversarial input, floor rule | `4436–4543` | issue-#465 and #464 sections | within-text multi-state-contract reconciliation; the adversarial-third-party-input dimension |
| Revision-delta verification coverage guard | `4545–4732` | issue-#559 section | every `no-options gate` occurrence classified; the shared Revision-delta verification block |

The generic test harness, registry validation, module registration, full-suite
boundary, and module-runner tests stay global so deleting this module cannot also
delete the checks that prove it is selected and executed. The shared pin/count/
mutation machinery lives in `module-harness.sh` (the namespaced `devflow_module_*`
API), so this module carries no private copy of it — it uses only `assert_eq`, that
namespaced API, and two domain-private classifiers (`ci559_classify` /
`ci559_field`) for the revision-delta coverage guard.
