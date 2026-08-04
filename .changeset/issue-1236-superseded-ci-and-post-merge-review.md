---
bump: patch
type: Fixed
---

- **Stop spending CI capacity and review tokens on results nobody reads.** `ci.yml` gains a
  workflow-level `concurrency:` key so a push that supersedes a still-running pull-request CI
  run cancels it, while `main` pushes are neither cancelled nor serialized (each merged commit
  is a distinct artifact). And `scripts/post-ci-review-trigger.sh` now checks the target pull
  request's state before posting an automatic `/prflow:review` request: a pull request that was
  merged or closed while CI was running gets no review request (its output would land on a dead
  target), and an unestablished state fails closed to not-posting with a `::warning::`. (#1236)
