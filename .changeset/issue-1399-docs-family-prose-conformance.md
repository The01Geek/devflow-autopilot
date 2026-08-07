---
bump: patch
type: Changed
---

- **The `docs-*` skill family now follows the instruction-plus-consequence prose rule.** Rationale
  essays, maintainer notes, reviewer pre-emptions and incident archaeology were removed from
  `docs-verify`, `docs-release-notes`, `docs-sync-internal`, `docs-sync-external` and
  `docs-bootstrap-internal`, so a `/prflow:docs` sweep spends less of its context on commentary
  before it starts work. Each skill's instructions, consequence sentences, scoping clauses,
  degraded arms and failure tokens are unchanged in effect. (#1411)
