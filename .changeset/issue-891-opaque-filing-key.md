---
bump: patch
type: Changed
---

- **Retrospective lifecycle records now carry an explicit `category` field so the filing key can be opaque.** `.devflow/learnings/overrides.json` moves to `schema_version: 3`: every lifecycle record gains a `category` string, and status derivation, the per-category filing cap, the cooldown lookup, and the report all read that stored category instead of re-deriving it from the record's key. `lib/pattern-state.sh migrate` stamps the field (existing valid category, else the key canonicalized through the new shared `lib/slugify.jq` module) and warns on a repaired record; a new `lib/compose-filing-key.sh` composes a collision-resistant ≤40-char key from a category and a subslug (python3/hashlib digest suffix on overflow); `lib/meta-issue.sh` takes a required `--category`; and `lib/filing-decisions.sh` gains `devflow_open_filed_for_category`, summing the `filed` count across every record sharing a category. Unblocks the sub-pattern filing-granularity work in #763. (#891)
