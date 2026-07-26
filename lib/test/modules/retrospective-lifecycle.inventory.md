# retrospective-lifecycle.sh — extracted-coverage inventory

Issue #788. This module owns the executable coverage for the retrospective
issue-closure lifecycle: the reconciler (`lib/pattern-state.sh`), the v2 overrides
migration, the six status arms of `lib/compute-patterns.jq`, the number-keyed
lifecycle write in `lib/meta-issue.sh`, the regressed occurrence-threshold bypass
and the liveness warning in `lib/actionable-patterns.sh`.

| Contract group | Former `lib/test/run.sh` location | Now |
| --- | --- | --- |
| `compute-patterns.jq` status derivation (open / fixed / regressed / dismissed, slug normalization, occurrence grouping) | `lib/test/run.sh` `compute-patterns.jq` block | Retained in `run.sh` (v1→v2 fixture shape updated in place); this module ADDS the new `declined`/`filed`/precedence/canonicalization arms (issue #788 introduced them, so they have no former run.sh home). |
| `meta-issue.sh` lifecycle write | `lib/test/run.sh` `meta-issue.sh` block | The permanent-`dismissed` assertions were rewritten in `run.sh` to the v2 lifecycle shape; this module ADDS the number-keyed de-dup single-entry assertion and the `--slug` grammar assertion. |
| `pattern-state.sh` migrate + reconcile transitions | new (issue #788) | This module (no former home — the helper is new). |
| `actionable-patterns.sh` regressed bypass + liveness warning | new (issue #788) | This module (the bypass and the liveness diagnostic are new behavior). |

Note (scope honesty): this module is additive coverage for the #788 mechanism. It
does not fully relocate the pre-existing inline `compute-patterns.jq` /
`meta-issue.sh` / `actionable-patterns.sh` / `render-report.sh` assertions out of
`lib/test/run.sh`; those remain inline (updated in place for the v2 shape). A
follow-up extraction can complete that relocation.
