---
title: "The PRFlow Lifecycle"
description: "Follow an issue through implementation, review, documentation and human merge."
---

# The PRFlow Lifecycle

This page follows seven lifecycle stages from issue preparation through human merge. PRFlow performs the middle stages through four implementation phases. The final merge remains human-controlled.

## 1. Issue

The GitHub issue is the change contract. PRFlow reads its description and acceptance criteria, checks declared dependencies and compares important claims with the repository before editing code.

The optional `create-issue` workflow clarifies unresolved decisions and requires explicit approval before it creates the issue.

## 2. Run

An implementation command starts the run. PRFlow loads repository guidance and configuration, then creates or resumes the issue workpad.

Local runs can ask you questions. Cloud runs use the issue and recorded workpad context because no person is present in the session.

## 3. Branch and Workpad

PRFlow creates, reuses or adopts a feature branch. It pushes the branch and records it in the workpad.

The workpad mirrors acceptance criteria and tracks setup, implementation, review, documentation and final pull-request state. A resumed run reads this comment and checks for an open pull request before deciding whether to create another branch.

## 4. Draft Pull Request

PRFlow explores the codebase, reproduces bug reports before planning when possible, implements the plan and runs repository verification. It commits and pushes the work, then opens a draft pull request that closes the issue.

The pull request stays draft while PRFlow performs its remaining review and documentation work.

## 5. Verification and Review

PRFlow runs the repository's configured tests and linters in the run environment. It then applies a cleanup pass and runs the review-and-fix loop.

The review engine builds a verification checklist, checks it against evidence and dispatches specialized reviewers. Findings can trigger fixes and another review iteration. Acceptance criteria must be satisfied or explicitly routed before the lifecycle can complete.

## 6. Documentation

PRFlow files follow-up issues for properly deferred work, updates relevant internal and external documentation, adds release-note material when needed and refreshes the pull-request description.

By default, the pull request is then published as ready for review. Repository configuration can leave it as a draft instead.

## 7. Human Merge

A person reviews the pull request, repository checks, workpad and review findings. Branch protection and the team's normal approval process still apply.

PRFlow never performs the merge. The lifecycle ends with a review-ready or deliberately draft pull request, not with code on the default branch.

## Related Documentation

- [Workpads and Resume](/docs/concepts/workpads-and-resume)
- [The Review System](/docs/concepts/review-system)
- [Human Control](/docs/concepts/human-control)
