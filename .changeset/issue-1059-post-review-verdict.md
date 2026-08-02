---
bump: patch
type: Fixed
---

- **Route the Phase 4.4 formal-review verdict post through the bundled `scripts/post-review-verdict.sh`
  helper with a closed outcome vocabulary, and make a failed post durable.** The review engine's
  verdict post was an unwrapped `gh pr review` porcelain invocation whose outcome the engine could
  observe only in its own per-turn transcript; when it failed on an APPROVE (observed on PR #1058) the
  approval survived only as a plain comment, the PR stayed wedged at `reviewDecision: CHANGES_REQUESTED`,
  and nothing durable recorded that the post had failed. The verdict now posts through a leading-token
  helper that emits exactly one of `POSTED`/`FAILED`/`SKIP …` (posting via `gh api` REST, body passed as
  a file path); on any non-`POSTED` outcome the engine posts the full report as a comment opening with a
  failure record (the failed post, its captured error, the verdict, and that the comment is not read as a
  verdict), and the stale-REJECT dismissal on an APPROVE now runs regardless of the post outcome with its
  result folded into that record. No verdict marker is minted and no consumer matcher changes — a failed
  post leaves `reviewDecision` and the reviews API exactly as before (#1030's owned concern). (#1059)
