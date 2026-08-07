---
title: "Human Control"
description: "See which decisions, permissions and merge actions remain with people."
---

PRFlow can prepare and review changes, but people retain authority over the repository. These boundaries clarify what the agent may do and which decisions remain yours.

## Before a Run

- The `create-issue` workflow displays the complete issue draft and waits for explicit approval before creating it.
- A local coding client can ask for clarification and tool permission during a run.
- Repository maintainers decide which configuration, prompt extensions and permission scopes to commit.
- Cloud comment triggers require an authorized collaborator or allowed bot. An outside fork contributor cannot start a privileged review run.

## During a Run

- Review permission requests at the narrowest useful scope.
- Inspect `Blocked` workpad entries before retriggering an implementation.
- Treat scope changes, deferred acceptance criteria and failed verification as decisions that need evidence, not inconveniences to bypass.
- Keep broad shell, filesystem and credential access outside the run unless the repository workflow genuinely needs it.

PRFlow can create issue comments, branches, commits, pull requests, reviews and follow-up issues when the active identity has permission. Those writes remain visible in Git and GitHub for review.

## Pull-Request State

Implementation opens a draft pull request before its review and documentation phases finish. The default completion path publishes it as ready for review. Maintainers can configure PRFlow to leave it as a draft.

Ready means the configured lifecycle completed. It does not mean a person approved the change, branch protection passed or deployment risk is acceptable.

## The Merge Boundary

PRFlow never merges a pull request. A human must:

1. Review the code, tests and documentation.
2. Read the workpad's acceptance-criteria evidence and reflections.
3. Evaluate review findings and any remaining caveats.
4. Wait for required repository checks and approvals.
5. Merge or request changes through the team's normal process.

This boundary is deliberate. PRFlow automates preparation and evidence gathering while leaving the irreversible integration decision with the repository's maintainers.
