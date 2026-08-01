---
bump: patch
type: Added
---

- **Ask for a standalone review automatically when CI goes green — in this repository only.** A new `auto-review notification` job in `.github/workflows/ci.yml` posts the bare review-trigger comment under a downscoped GitHub App token once both CI jobs pass on a non-draft, same-repository pull request, deduped per head SHA by a `<!-- prflow:ci-review-trigger sha=… -->` marker read from the pull request's comments. The post-or-skip selection lives in the new `scripts/post-ci-review-trigger.sh` so the suite can drive each arm; an unreadable comment list fails **closed** (a duplicate standalone review is unrecoverable spend, a missed one is recoverable by the pre-existing human-comment path). **Nothing changes for consumers:** `install.sh` ships only `devflow.yml` and `devflow-implement.yml`, so no consumer repository has `ci.yml`, nothing consumer-facing calls the new helper, and a collaborator commenting the trigger remains the supported review path everywhere else.
