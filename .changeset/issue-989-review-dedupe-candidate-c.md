---
bump: patch
---

Fixed: `devflow.yml`'s `review_dedupe` job now suppresses a duplicate standalone
`/prflow:review` while a review of the same pull request is already in flight, so
a pull request receives one review instead of several billed engine runs and
duplicate verdicts (PR #993, issue #989). Detection reads the review engine's
seeded `devflow:review-progress` comment (`🚀 Reviewing`, bot-authored,
liveness-bounded) via the new bundled `scripts/dedupe-review-command.sh` helper.
The job keeps its fail-open contract, keeps its `/prflow:review-and-fix`
exemption, never suppresses a `devflow:review-backstop` auto-resume, and posts a
notice describing the actual state. The suppression is **pull-request-scoped,
not commit-scoped** — the seeded comment carries no head while the review is in
flight — so a review requested after pushing a new commit, while the earlier
review is still running, is also skipped; comment again once that review has
posted its verdict. Both legacy signals (the `Devflow Review`
check-run and `devflow-review.yml` run queries) are retained for consumers whose
installed copy predates the withheld auto-review tier.
