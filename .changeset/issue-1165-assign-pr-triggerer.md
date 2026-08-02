---
bump: patch
type: Added
---

- **Assign implement-created pull requests to the triggering user.** After `/prflow:implement`'s CREATE path opens a draft PR, a new best-effort helper (`scripts/apply-pr-triggerer.sh`) assigns it to the developer who triggered the run — the authorized comment sender on cloud runs (propagated through `DEVFLOW_TRIGGERING_USER`), the authenticated `gh` login on local runs — so reviewers can read ownership from the standard GitHub assignee field. Assignment is confirmed against the API response, is idempotent, is fail-closed on identity (an empty cloud sender substitutes no other account), leaves adopted PRs untouched, and records any skip as a `dropped-failed` workpad reflection without ever gating the run. (#1165)
