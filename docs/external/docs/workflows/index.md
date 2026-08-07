---
title: "Workflows"
description: "Choose the PRFlow workflow that matches the outcome and edit authority you want."
---

Choose the smallest PRFlow workflow that can produce the outcome you need with the appropriate edit authority.

The diagram uses PRFlow skill names without a client-specific command prefix. The command examples below show how to invoke them in each supported client.

![A map of PRFlow skills grouped by outcome. The core delivery skills are prflow:create-issue, prflow:implement, prflow:review and prflow:review-and-fix. Supporting skills are prflow:pr-description, prflow:docs and prflow:retrospective-weekly.](/images/workflow-skill-map.svg)

## Choose a Workflow

| **Goal** | **Workflow** | **What It Can Change** | **Expected Result** |
| --- | --- | --- | --- |
| Turn an idea or bug report into a ticket | [Create an Issue](/docs/workflows/create-issue) | Creates one approved GitHub issue | An approved issue. It is implementation-ready only when its Blocked section has no unresolved decision. |
| Complete an existing issue | [Implement](/docs/workflows/implement) | Creates a branch, commits code and docs, pushes and opens a pull request | A review-ready or draft pull request with recorded verification evidence, or a Blocked result naming the required human action |
| Assess a pull request or branch | [Review](/docs/workflows/review) | Does not edit the reviewed tree | Findings and an APPROVE or REJECT verdict |
| Assess changes and authorize corrections | [Review and Fix](/docs/workflows/review-and-fix) | Commits corrections to the target branch | Corrections followed by recorded verification, or a report naming unresolved findings |
| Generate or refresh a pull request body | [Pull Request Description](/docs/workflows/pr-description) | Updates the current branch's pull request body when one exists | A structured, current description |
| Maintain developer docs, public docs or release notes | [Documentation](/docs/workflows/documentation) | Edits the selected documentation files | Documentation aligned with the current change |
| Learn from recently merged pull requests | [Weekly Retrospective](/docs/workflows/retrospective-weekly) | Updates learning records, opens or updates a state pull request and files selected GitHub issues | A state pull request, human-triage issues and a report |

Use `review` for an assessment with no code edits. Use `review-and-fix` only when you explicitly authorize PRFlow to make and commit corrections.

## Command Syntax

PRFlow commands use different prefixes in supported local clients:

| **Client** | **Example** |
| --- | --- |
| Claude Code | `/prflow:review 123` |
| GitHub Copilot CLI | `/prflow/review 123` |
| Codex CLI | `$prflow:review 123` |

Supported GitHub comment commands always use the Claude-style `/prflow:` prefix. See the [command reference](/docs/reference/command-reference) for arguments, availability and mutation authority.

## Related Articles

- [Command Reference](/docs/reference/command-reference)
- [Local Runs](/docs/runs/local/index)
- [Cloud Runs](/docs/runs/cloud/index)
