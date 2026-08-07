---
bump: patch
type: Changed
---

- **Five `docs-*` skills were brought into conformance with the instruction-plus-consequence prose
  rule.** Rationale essays, maintainer notes, reviewer pre-emptions and incident archaeology were
  removed from `docs-verify`, `docs-release-notes`, `docs-sync-internal`, `docs-sync-external` and
  `docs-bootstrap-internal`, so every `/prflow:docs`, `/prflow:docs-sync-*`,
  `/prflow:docs-bootstrap-internal`, `/prflow:docs-release-notes` and `/prflow:docs-verify` run spends less
  of its context on commentary before it starts work. `docs-bootstrap-external` and `docs-verify`'s
  write-mode reference already conformed and are unchanged. One behavior change ships with the pass:
  `docs-bootstrap-internal` now tells the agent to leave its `.gitkeep` files in place, where before
  it only described them as superseded. (#1411)
