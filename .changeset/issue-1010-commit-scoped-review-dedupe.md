---
bump: patch
type: Changed
---

- **`review_dedupe` is now commit-scoped, not pull-request-scoped.** A `/prflow:review`
  requested while a review of a *different* head is in flight now proceeds instead of being
  suppressed, so pushing a commit mid-review and asking for a review no longer makes you wait
  for the earlier review to finish. The review engine stamps the head it is reviewing into the
  live progress comment it seeds at Phase 0.3.5, as a new machine-only producer key —
  `<!-- prflow:review-seeded-head <sha> -->` — carried in the comment template so every
  in-place rewrite re-emits it. The key is deliberately distinct from that comment's
  `Reviewed HEAD:` line, whose meaning ("a review *finished* at this head") two consumers
  depend on and which is unchanged. The value recorded is the PR's API `headRefOid` captured
  before any caller head-override, so a `/prflow:review` issued during a
  `/prflow:review-and-fix` fix loop — whose head is a locally-committed, possibly unpushed
  SHA — is still suppressed. An in-flight review seeded by an installed copy predating this
  change carries no such key and fails **open** with a breadcrumb naming it, so an upgraded
  workflow never suppresses on a head it could not establish. The suppression notice now names
  the commit and states commit scope. (#1010)
