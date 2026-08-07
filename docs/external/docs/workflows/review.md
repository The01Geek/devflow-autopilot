---
title: "Review"
description: "Assess a pull request or branch without changing the reviewed tree."
---

Use this workflow when you want findings, verification results and a review verdict for human evaluation without authorizing code edits. It does not change the reviewed tree. The result is a report and verdict, or a report naming incomplete checks and any missing GitHub review signal.

```text
/prflow:review 123
```

Omit the pull request number to review the current branch against the configured base branch. Add `--issue N` to use a specific issue's acceptance criteria.

## Review Targets

In pull request mode, PRFlow reviews the pushed pull request head and uses the pull request's base. Local uncommitted changes are not included.

In current-branch mode, PRFlow reviews committed changes between `HEAD` and the configured `base_branch`. Commit the changes you want assessed before starting.

## What the Review Covers

The review engine classifies the diff, builds and verifies a change-specific checklist, runs specialized review agents and aggregates the results. It evaluates correctness, silent failures, tests, type design, issue compliance and relevant review comments.

A failed or inconclusive verification checklist item causes REJECT. Code findings cause REJECT when they meet the configured verdict severity threshold. Lower-severity findings remain visible as notes.

## Mutation Boundary

Review does not edit, commit, check out or push the reviewed tree. It can write ephemeral review scratch data and, in pull request mode, maintain a progress comment and post the final GitHub review.

Use [Review and Fix](/docs/workflows/review-and-fix) only when you explicitly want PRFlow to correct verified findings.

## Expected Result

Current-branch mode returns the full report and verdict in chat.

Pull request mode also attempts to post a formal GitHub review:

- A clean APPROVE posts an approval.
- REJECT posts a request for changes.
- An approval-side verdict with notes or a caveat posts a comment review.

If the formal review cannot be posted, PRFlow records the report through the available fallback channel and reports that the merge signal is missing. PRFlow never merges the pull request.

## Related Articles

- [Review and Fix](/docs/workflows/review-and-fix)
- [Review Agents](/docs/configuration/review-agents)
- [Command Reference](/docs/reference/command-reference)
