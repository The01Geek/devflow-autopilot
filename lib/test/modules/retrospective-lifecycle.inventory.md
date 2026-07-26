# retrospective-lifecycle.sh — extracted-coverage inventory

Issue #788. This module owns the executable coverage for the retrospective
issue-closure lifecycle: the reconciler (`lib/pattern-state.sh`), the v2 overrides
migration, the status arms of `lib/compute-patterns.jq`, the number-keyed
lifecycle write in `lib/meta-issue.sh`, the regressed occurrence-threshold bypass
and the liveness warning in `lib/actionable-patterns.sh`, and the filing decisions
and report-field producers in `lib/filing-decisions.sh`.

| Contract group | Former `lib/test/run.sh` location | Now |
| --- | --- | --- |
| `compute-patterns.jq` status derivation (open / fixed / regressed / dismissed, slug normalization, occurrence grouping) | `lib/test/run.sh` `compute-patterns.jq` block | **Relocated into this module**, together with the `declined`/`filed`/precedence/canonicalization arms #788 introduced. |
| `meta-issue.sh` lifecycle write, de-dup, `--dry-run`, URL-shape and `--slug` grammar guards | `lib/test/run.sh` `meta-issue.sh` block | **Relocated into this module**, together with the number-keyed single-entry assertion. |
| `pattern-state.sh` migrate + reconcile transitions | new (issue #788) | This module (no former home — the helper is new). |
| `actionable-patterns.sh` regressed bypass + liveness warning | new (issue #788) | This module (the bypass and the liveness diagnostic are new behavior). |
| `filing-decisions.sh` cap arms + arm order + fail-closed operands; liveness capture, won't-fix re-raise, per-pattern annotation; end-to-end render of every report section | new (issue #788) | This module (the helper is new — it is the executable owner of decisions that were previously Step 8c/9 prose). |

## What deliberately stayed in `lib/test/run.sh`

The two repo-wide tracked-surface prose guards that used to sit under the
`compute-patterns.jq` section header — the `#129` removed-slug lockstep scan and
the `#412` `config.json`-tracking claim scan — are **not** `compute-patterns.jq`
coverage. Each `git grep`s every tracked file in the repository, so neither
belongs to this module's ownership set in `coverage-map.json`; both remain in the
monolith under their own section header.

## Line-count evidence (AC)

The reduction is **reported by the module on its passing path**, not checked in
here: the module resolves this change's merge-base, prints the before/after
`lib/test/run.sh` line counts, and asserts the file is shorter than it was at
that base. A checked-in figure would rot as `run.sh` moves under other work,
which is exactly why the assertion measures instead.
