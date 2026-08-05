---
bump: patch
type: Fixed
---

- **A review run whose `command` job dies now still leaves a truthful, PR-visible record.** Every review post-run handler on `devflow.yml`'s `command` job was an `always()`-conditioned step inside that job, so a runner death (OOM, eviction, infrastructure loss) took all of them down with the job — the one failure mode they existed to cover. A new out-of-job `review_finalize` job (which does not share a runner with the `claude` step) now reads `needs.command.result` plus the GitHub API and, when the review command job did not report, flips the frozen `🚀 Reviewing` progress comment to a terminal "did not report" state naming the run URL. The flip is idempotent, so it never stacks a second banner and never fights the surviving in-job copy on an alive failure. Covers both `/prflow:review` and `/prflow:review-and-fix`. (#1174)
