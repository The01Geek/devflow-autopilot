---
bump: patch
type: Security
---

- **`devflow.yml` now subscribes to `issue_comment` alone and pins every checkout to the default branch.** The two review-triggered subscriptions (`pull_request_review[submitted]` and `pull_request_review_comment[created]`) were removed: on those events GitHub resolved `GITHUB_REF` to the pull-request merge ref, so every job — `config`, `review_dedupe`, `gate`, and `command` — checked out pull-request-author content, including the `config` job's authorization inputs (`prflow.allowed_users`/`allowed_bots`/`allowed_tools`) and the agent's tool grants. Each checkout now pins `ref: ${{ github.event.repository.default_branch }}` so the trusted-workspace property is stated in the file rather than inferred from the trigger set. Requesting a review by commenting on the pull-request conversation still works; requesting one from the review-submission box or an inline diff comment no longer does. This closes the accident class (a pull request's content executed by a review-triggered run with nobody intending it); the adversarial residual — a branch that re-adds a trigger or drops a pin in its own copy of the workflow — is tracked in #1300. (#1163)
