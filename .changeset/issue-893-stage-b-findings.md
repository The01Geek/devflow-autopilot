---
bump: patch
---

Let Stage B name sub-patterns and file one issue per finding, ranked and capped (issue #893).

- `lib/compute-patterns.jq` now carries each occurrence's own `summary`, `descriptors`, and `suggested_interventions` (with absent- and wrong-typed-field defaults that never drop the occurrence or lower `occurrence_count`), so Stage B clusters sub-patterns from the on-disk pattern object instead of reopening every context bundle.
- New `lib/select-findings.sh` is the sole owner of which Stage B findings become filings: it composes and legality-checks each filing key through the #891 composer, collapses subslug churn onto an existing lifecycle record by a deterministic token-set alias, ranks tight clusters ahead of grab-bags (descending evidence-PR count) and truncates to the top three, and asks the shipped `devflow_filing_cap_verdict` for every cap decision. It withholds (never files uncapped) when the cap owner cannot be sourced or the overrides file is absent/unreadable/unmigrated.
- Stage B (`skills/retrospective-audit`) now returns a ranked `findings` array of one to three elements — each with its own `subslug`, `title`, `body`, `evidence_prs`, and `rationale` — and the weekly orchestrator files one issue per selected finding under an opaque `<category>-<subslug>` key, so sub-patterns get their own keys and lifecycle instead of being lost to prose.
- The run report names each filed issue by both its filing key and its category.
