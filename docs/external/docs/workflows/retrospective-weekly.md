---
title: "Weekly Retrospective"
description: "Run PRFlow's local, human-governed learning loop over recently merged pull requests."
---

# Weekly Retrospective

Use this workflow when you want to turn recurring delivery problems into bounded issues for human triage. It changes the local checkout and writes learning records. It can also create GitHub issues and a state pull request. The result is a report with those records or explicit blockers.

This is a mutating local workflow. It requires a clean working tree and can switch the checkout to `main`. It writes learning records, opens or updates a state pull request and files selected findings as GitHub issues. It never edits product code or merges a pull request.

```text
/prflow:retrospective-weekly
```

This workflow runs locally. It is not a scheduled cloud command.

## Prerequisites

Before it starts, PRFlow requires:

- A clean working tree.
- An authenticated GitHub CLI session. Run `gh auth login` if authentication fails.
- The repository's `main` branch checked out. PRFlow switches to `main` when needed.

The clean-tree requirement prevents unrelated changes from entering the retrospective state pull request.

## What It Scans

The normal weekly scan finds watched-author pull requests that were merged in the last seven days and are not already recorded as processed. Pull requests with no signal that warrants further analysis receive a compact clean entry. Other eligible pull requests receive a bounded retrospective analysis.

PRFlow writes the results to `.prflow/learnings/` and derives recurring actionable patterns. It limits how many pull request records are used to reassess each pattern.

## Bounded Proposals

Filing controls limit the number of issues created in one run, the total number of open retrospective issues and the number open in one category. A pattern with missing evidence or an invalid cap is withheld instead of filed speculatively.

Each selected finding becomes one GitHub issue for human triage. The issue proposes the smallest change that could prevent another occurrence.

## State Pull Request

PRFlow opens or updates a separate state pull request containing the retrospective records. It returns to `main` before it files proposed issues.

Review the state pull request and merge it manually after continuous integration passes. PRFlow never merges it.

## Human Governance Boundary

The retrospective loop does not edit product code. It does not implement its proposed issues and does not merge any pull request.

Humans decide which findings are worth pursuing. Selected issues then move through the normal [Implement](/docs/workflows/implement) and [Review](/docs/workflows/review) workflows.

## Expected Result

The run returns a report, a state pull request, any filed issues and explicit blockers. A later run processes only newly eligible pull requests and avoids refiling an already tracked pattern.

## Related Articles

- [Create an Issue](/docs/workflows/create-issue)
- [Implement an Issue](/docs/workflows/implement)
- [Glossary](/docs/reference/glossary)
