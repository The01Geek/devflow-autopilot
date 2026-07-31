---
bump: patch
type: Added
---

Declared `## Dependencies` prerequisites are now registered as GitHub-native blocked-by dependencies after issue creation. Both post-creation producers — `/prflow:create-issue` Step 4 and `/prflow:implement` Phase 4.0's deferred follow-ups — stamp them through the new best-effort helper `scripts/apply-issue-dependencies.py`, the third member of the post-creation REST-stamp family beside `ensure-label.sh`/`apply-labels.sh`. The helper fetches the created issue's body itself, derives prerequisites through a section-scoped recognizer factored out of `scripts/preflight.py` (skipping numbers that resolve to a pull request or to the issue's own number), always exits 0, never blocks or reverses creation, and breadcrumbs every outcome. A blocked DevFlow issue now shows as blocked in GitHub's own issue header, issue list, and project views without anyone reading the body (issue #1011).
