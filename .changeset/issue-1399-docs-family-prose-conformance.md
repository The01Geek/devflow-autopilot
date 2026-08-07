---
bump: patch
type: Changed
---

- **The `docs-*` skill family now follows the instruction-plus-consequence prose rule.** Rationale
  essays, maintainer notes, reviewer pre-emptions and incident archaeology were removed from
  `docs-verify`, `docs-release-notes`, `docs-sync-internal`, `docs-sync-external` and
  `docs-bootstrap-internal`, so a `/prflow:docs` sweep spends less of its context on commentary
  before it starts work. Each hunk in the diff was read against that rule, and none of them removed
  an instruction, a consequence sentence, a scoping clause, a degraded arm or a failure token.
  (#1411)
