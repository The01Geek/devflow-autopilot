# Review stall-backstop contract module inventory

This inventory records the provenance of the focused review stall-backstop contract
module (issue #746, the measured first modularization tranche). It is a navigation
aid, not a second source of behavior: `review-stall-backstop.sh` owns the executable
assertions, and the complete suite calls the same module through
`module-harness.sh`'s `devflow_run_full_suite_module` boundary.

Source baseline: `2e9283f4` (`origin/main` after issue #745 landed).

The extracted region was **2 adjacent box-comment sections** in `lib/test/run.sh`,
853 lines carrying 128 assertions (107 `assert_eq`, 10 `assert_pin_unique`, 11
`assert_pin_red_under`): `#408 cloud review no-verdict auto-resume backstop` and
`#414 review stall-backstop post-and-annotate helper extraction`. The floor is 124,
four below the measured 128.

| Contract group | Former `lib/test/run.sh` section | Module destination | Representative contract |
| --- | --- | --- | --- |
| Fire / no-fire decision | `#408` head | `review-stall-backstop.sh` / decision section | `request-review-backstop.sh` owns the whole decision (config read, verdict guard, per-head attempt count, App-token guard, marker construction), every arm drivable with a stubbed `gh` |
| Guarantee-class arm | `#408` guarantee rows | decision section | an incomplete run is treated as a no-verdict resume candidate, never silently as a pass |
| Workflow wiring | `#408` `devflow-review.yml` / `devflow.yml` rows | wiring section | the backstop step is wired on both the auto and manual paths with a step-scoped `HEAD_SHA` |
| Grounding-block coupling | `#408` `render-grounding-block.sh` rows | wiring section | the resume path carries the rendered grounding block rather than a second hand-copied one |
| Review-skill coupling | `#408` bundle pins | bundle-pin section | the headless-wait discipline sentences survive somewhere in the review engine bundle |
| Post-and-annotate helper | `#414` head | post-and-annotate section | `post-review-backstop-comment.sh` posts and annotates as one extracted helper |
| Probe verdict readers | `#414` `schedulewakeup-probe-verdict.py` / `agents-seam-probe-verdict.py` rows | probe-verdict section | each reader's verdict arms, including the unestablished-measurement arm |

The generic test harness, registry validation, module registration, full-suite
boundary, and module-runner tests stay global so deleting this module cannot also
delete the checks that prove it is selected and executed.

Rewrite performed during extraction: the 10 `assert_pin_unique` calls became
`devflow_module_pin_unique` and the 11 `assert_pin_red_under` calls became
`devflow_module_pin_red_under` — a mechanical 1:1 rename onto the namespaced module
pin API, literals, mutations and targets unchanged. Two run.sh globals are
re-derived in the module header rather than inherited:

- `REPO_ROOT`, computed from `LIB` exactly as the monolith computes it.
- `REVIEW_BUNDLE`, the concatenated review-engine bundle (thin root plus every
  phase reference) that two `#408` pins target so their sentences may live in the
  root or in any reference. The module rebuilds it with
  `devflow_module_build_bundle`, promoted into `lib/test/module-harness.sh` by this
  same change rather than hand-rolled a third time (`create-issue-contract.sh` and
  `review-and-fix-contract.sh` each carried their own copy). Membership is derived
  from the tree — every `skills/review/phases/*.md` — never transcribed, so a phase
  reference added later cannot be silently omitted from the bundle the survival
  pins assert against.

Coverage-map ownership for the moved labels is recorded in
`lib/test/modules/coverage-map.json`.
