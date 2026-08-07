---
title: "First Run"
description: "Turn a user story, feature request or existing issue into a review-ready pull request."
---

Start with a user story, feature request or existing GitHub issue. PRFlow helps you create an approved issue when needed, then turns it into a pull request for human review.

## Before You Start

Confirm that:

- The current directory is inside the Git repository you want to change.
- The intended GitHub repository is available as the `origin` remote.
- `gh auth status` succeeds for an identity that can read the issue and create issue comments, branches and pull requests.
- The repository's tests and linters can run from the local environment.
- The issue has a clear outcome and verifiable acceptance criteria.

Initialization is not a prerequisite. Local defaults work without `.prflow/config.json`.

## 1. Create or Select an Issue

Skip this step when a suitable issue already exists. Otherwise, use the syntax for your client:

| **Client** | **Create-Issue Command** |
| --- | --- |
| Claude Code | `/prflow:create-issue Add an option to retain completed run logs for 30 days` |
| GitHub Copilot CLI | `/prflow/create-issue Add an option to retain completed run logs for 30 days` |
| Codex CLI | `$prflow:create-issue Add an option to retain completed run logs for 30 days` |

PRFlow clarifies unresolved decisions, displays the complete issue draft and creates the issue only after you explicitly approve that draft.

## 2. Implement the Issue

Replace `123` with the issue number:

| **Client** | **Implement Command** |
| --- | --- |
| Claude Code | `/prflow:implement 123` |
| GitHub Copilot CLI | `/prflow/implement 123` |
| Codex CLI | `$prflow:implement 123` |

PRFlow fetches the issue, mirrors its acceptance criteria into a workpad, plans the change, implements it, runs repository verification, reviews the diff and updates relevant documentation.

## What to Expect

A fresh run normally produces these visible artifacts:

- **Branch:** A branch named `issue-<number>-<title-slug>`. PRFlow adds a date suffix when the unsuffixed name already exists. A resumed run can adopt the head branch of an existing open pull request instead.
- **Workpad:** One dedicated progress comment on the GitHub issue. It records status, branch, plan, acceptance criteria, progress and notable limitations. The same comment is updated throughout the run.
- **Pull request:** A draft pull request is opened during review. By default, PRFlow publishes it as ready for review only after verification, review and documentation finish. A repository can configure implementation runs to leave it as a draft.

PRFlow can stop with a `Blocked` status when a dependency, acceptance criterion, verification command or repository state needs human action. Resolve the recorded cause, then run implementation again. PRFlow can resume from the latest workpad and pushed branch checkpoint. Work after that checkpoint may need to be repeated.

## 3. Review and Merge

Review the code, tests, documentation, acceptance-criteria evidence and any workpad reflections. Run an additional [standalone review](/docs/workflows/review) when you want an independent verdict.

PRFlow never merges the pull request. Merge it through your repository's normal human review and branch-protection process.

Learn the complete sequence in [The PRFlow Lifecycle](/docs/concepts/lifecycle).
