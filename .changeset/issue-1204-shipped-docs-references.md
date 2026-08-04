---
bump: patch
type: Changed
---

- **Removed PRFlow-internal `docs/` references from the shipped `scripts/`, `lib/`, and config-schema surfaces.** These files vendor into consumer repos, where the maintainer `docs/` tree does not resolve — most notably `resolve-review-overrides.py`'s `::notice::` string and the `prflow_review.agent_overrides` schema description, both of which a consumer's review run surfaces. 63 of the 65 references were removed (maintainer navigation pointers) or replaced (runtime-emitted diagnostics and schema descriptions, restated inline); the two remaining are functional references (`generate-env-freeze-advisory.py`'s `REGION_FILE` constant and `rename-map.json`'s programmatically-read `consumer_docs` list) that the internal-docs move will re-path. (#1204)
