---
bump: patch
---

Fixed: `devflow.yml`'s `review_dedupe` job now suppresses a duplicate standalone
`/prflow:review` while a review of the same commit is already in flight, so one
pull-request head receives one review instead of several billed engine runs and
duplicate verdicts (PR #993, issue #989). Detection reads the review engine's
seeded `devflow:review-progress` comment (`🚀 Reviewing`, bot-authored,
liveness-bounded) via the new bundled `scripts/dedupe-review-command.sh` helper.
The job keeps its fail-open contract, keeps its `/prflow:review-and-fix`
exemption, never suppresses a `devflow:review-backstop` auto-resume, and posts a
notice describing the actual state. Both legacy signals (the `Devflow Review`
check-run and `devflow-review.yml` run queries) are retained for consumers whose
installed copy predates the withheld auto-review tier.
