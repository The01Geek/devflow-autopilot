---
bump: patch
---

Retrospective cheap-gate: `review_reject_outstanding` now reads the durable bot PR reviews, not only the conversation comments (issue #895)

`lib/fetch-pr-context.sh` derives `review_verdicts` from the **union** of the PR conversation comments and the durable bot PR reviews already fetched into `pr_reviews`. Previously the signal came only from the conversation comments, so a `/review` run that left no progress comment — its verdict living solely in the `gh pr review` body — made the retrospective's cheap gate fail **open**: a PR merged over an un-cleared REJECT read as clean and was silently dropped from analysis.

Both legs recognize the verdict heading with the same grammar; the verdict token always comes from the body, never the review state. A review contributes when its state is not `PENDING` and its body carries a heading; a `DISMISSED` review still contributes (the retrospective deliberately inverts the merge gate's dismissal rule). Union entries carry a `source` field (`pr_comment`/`pr_review`), and a timestamp-less entry can only raise non-cleanliness, never lower it. The two verdict payloads reach jq via stdin and `--slurpfile`, never `--argjson`; `lib/fetch-pr-context.sh` is now audited by `lib/test/lint-argjson-transport.py`.

`lib/cheap-gate.jq` now **fails closed** with the reason `review-verdict signal unreadable` (evaluated before every other arm) when `.signals` is not an object or `review_reject_outstanding` is absent/null/non-boolean, and `lib/dispatch-disposition.jq` tolerates a non-object `.signals` (routing to `dispatch`). No merge gate is affected — this signal is read only by the weekly retrospective pipeline.
