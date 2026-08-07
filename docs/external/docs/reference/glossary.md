---
title: "Glossary"
description: "Understand the terms PRFlow uses for issues, branches, reviews and human control."
---

Use this glossary to understand PRFlow terms without needing to know the product's internal implementation.

**Acceptance criteria**: Testable statements in an issue that define when the requested outcome is complete.

**Base branch**: The repository branch a feature branch or pull request is compared with, such as `main`.

**Cloud run**: A supported PRFlow command executed by repository automation after an authorized GitHub comment.

**Deferred finding**: A verified review concern that is intentionally not fixed in the current pull request and is disclosed with a follow-up record.

**Draft pull request**: A pull request that is open but not yet published as ready for review.

**Feature branch**: The branch that holds the commits for one issue or pull request.

**Formal review**: A GitHub pull request review that records an approval, comment or request for changes. A comment review is a durable report but does not create an approval or request-changes merge signal.

**Human merge boundary**: The rule that PRFlow prepares and reviews pull requests but a person owns the final merge decision.

**Local run**: A PRFlow skill executed in the user's active Claude Code, GitHub Copilot CLI or Codex CLI session.

**Post-merge verification**: An acceptance check that requires a deployed or other genuinely live environment and must run after merge.

**PRFlow**: A plugin that prepares documented pull requests with verification and review evidence for human evaluation.

**Ready for review**: A pull request state that tells reviewers the authoring workflow is complete. It does not mean the pull request has been approved or merged.

**Review-and-fix loop**: A bounded cycle that reviews a candidate, verifies findings, commits authorized fixes and reviews the result again.

**Shadow review**: A separate review pass that looks for significant findings missed by the primary review-and-fix loop. It reports which planned reviewers completed and any known coverage gaps, but it cannot prove that every defect was found.

**State pull request**: A pull request containing retrospective learning records instead of product-code changes. A human reviews and merges it.

**Workpad**: The single GitHub issue comment that records an implementation run's branch, status, plan, progress, acceptance criteria and important recovery notes.

## Related Articles

- [Command Reference](/docs/reference/command-reference)
- [Workflows](/docs/workflows/index)
