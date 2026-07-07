---
bump: patch
type: Fixed
---

- **Review preconditions now surface the underlying `gh` error in their breadcrumbs.** Each `gh api` failure arm in `scripts/derive-review-preconditions.sh` (the branch-freshness compare, the workflow-runs, combined-status, and check-runs queries) now captures `gh`'s own stderr into its "query failed" breadcrumb — mirroring `resolve_pr_for_head` — so an operator debugging a permanently-deferred auto-review sees the real cause (rate limit, 403 token-scope, 5xx) instead of a bare "query failed". Also documents the behind-base deferral base-advance limitation in `docs/workflow-triggers.md` and adds a post-install reminder to set the `workflow_run` CI workflow name(s). (#319)
