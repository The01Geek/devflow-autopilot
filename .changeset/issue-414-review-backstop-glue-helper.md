---
bump: patch
type: Changed
---

- **Extract the review stall-backstop post-and-annotate glue into a shared helper.** The
  ~40-line block that both `devflow-review.yml` and `devflow.yml` duplicated byte-for-byte —
  parse the `request-review-backstop.sh` decision, compose the `/devflow:review` re-trigger
  body, POST it via `post-issue-comment.sh`, and select the `::notice::`/`::warning::`
  annotation on the POST success breadcrumb — now lives once in
  `scripts/post-review-backstop-comment.sh`. `lib/test/run.sh` drives the notice-vs-warning
  selection (including the fail-closed arm where a failed/absent POST is never annotated as a
  fired re-trigger) instead of only presence-pinning a breadcrumb literal in each workflow.
  `request-review-backstop.sh`'s decision contract is unchanged. (#416)
